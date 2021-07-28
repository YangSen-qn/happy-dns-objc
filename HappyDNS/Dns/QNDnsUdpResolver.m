//
//  QNDnsServer.m
//  Doh
//
//  Created by yangsen on 2021/7/20.
//

#import "QNRecord.h"
#import "QNDomain.h"
#import "QNDnsError.h"
#import "QNDnsUdpResolver.h"
#import <QNAsyncUdpSocket.h>

@interface QNDnsFlow : NSObject

@property(nonatomic, assign)long flowId;
@property(nonatomic,   copy)NSString *server;
@property(nonatomic, strong)QNDnsRequest *dnsRequest;
@property(nonatomic, strong)QNAsyncUdpSocket *socket;
@property(nonatomic,   copy)void(^complete)(QNDnsResponse *response, NSError *error);

@end
@implementation QNDnsFlow
@end

#define kMinPort 10000
#define kMaxPort (0xFFFF)
#define kDnsPort 53
#define kGetPortMaxTime 10
@interface QNDnsUdpResolver()<QNAsyncUdpSocketDelegate>

@property(nonatomic, strong)dispatch_queue_t queue;
@property(nonatomic, strong)NSMutableDictionary *flows;

@end
@implementation QNDnsUdpResolver

+ (instancetype)resolverWithServerIP:(NSString *)serverIP
                             timeout:(int)timeout {
    return [super resolverWithServer:serverIP timeout:timeout];
}

+ (instancetype)resolverWithServerIPs:(NSArray <NSString *> *)serverIPs
                              timeout:(int)timeout {
    return [super resolverWithServers:serverIPs timeout:timeout];
}

+ (instancetype)resolverWithServerIPs:(NSArray <NSString *> *)servers
                                queue:(dispatch_queue_t _Nullable)queue
                              timeout:(int)timeout {
    QNDnsUdpResolver *resolver = [super resolverWithServers:servers timeout:timeout];
    resolver.queue = queue;
    return resolver;
}

- (dispatch_queue_t)queue {
    if (_queue == nil) {
        _queue = dispatch_queue_create("com.qiniu.dns.server.queue", DISPATCH_QUEUE_CONCURRENT);
    }
    return _queue;
}

- (NSMutableDictionary *)flows {
    if (_flows == nil) {
        _flows = [NSMutableDictionary dictionary];
    }
    return _flows;
}

//- (NSArray *)query:(QNDomain *)domain networkInfo:(QNNetworkInfo *)netInfo error:(NSError *__autoreleasing *)error {
//
//    NSError *err = nil;
//    QNDnsResponse *response = [self lookupHost:domain.domain recordType:kQNTypeA error:&err];
//    if (err != nil) {
//        *error = err;
//        return @[];
//    }
//
//    NSMutableArray *records = [NSMutableArray array];
//    for (QNRecord *record in response.answerArray) {
//        if (record.type == kQNTypeA || record.type == kQNTypeAAAA) {
//            [records addObject:record];
//        }
//    }
//    return [records copy];
//}
//
//- (QNDnsResponse *)lookupHost:(NSString *)host
//                   recordType:(int)recordType
//                        error:(NSError *__autoreleasing  _Nullable *)error {
//    if (self.servers == nil || self.servers.count == 0) {
//        if (error != nil) {
//            *error = kQNDnsInvalidParamError(@"server can not be empty");
//        }
//        return nil;
//    }
//
//    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
//
//    __block NSError *errorP = nil;
//    __block QNDnsResponse *dnsResponse = nil;
//    for (NSString *server in self.servers) {
//        [self request:server host:host recordType:recordType complete:^(QNDnsResponse *response, NSError *err) {
//            errorP = err;
//            dnsResponse = response;
//            dispatch_semaphore_signal(semaphore);
//        }];
//    }
//
//    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, self.timeout * NSEC_PER_SEC));
//
//    if (error != NULL) {
//        *error = errorP;
//    }
//
//    return dnsResponse;
//}

- (void)request:(NSString *)server
           host:(NSString *)host
     recordType:(int)recordType
       complete:(void(^)(QNDnsResponse *response, NSError *error))complete {
    if (complete == nil) {
        return;
    }
    
    int messageId = arc4random()%(0xFFFF);
    QNDnsRequest *dnsRequest = [QNDnsRequest request:messageId recordType:recordType host:host];
    
    NSError *error = nil;
    NSData *requestData = [dnsRequest toDnsQuestionData:&error];
    if (error) {
        complete(nil, error);
        return;
    }
    
    QNAsyncUdpSocket *socket = [[QNAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:self.queue];
    int time = 0;
    while (time < kGetPortMaxTime) {
        [socket bindToPort:[self refreshPort] error: &error];
        if (!error) {
            break;
        }
        error = nil;
        time++;
    }
    if (error) {
        complete(nil, error);
        return;
    }
    
    [socket beginReceiving:&error];
    if (error) {
        complete(nil, error);
        return;
    }
    
    QNDnsFlow *flow = [[QNDnsFlow alloc] init];
    flow.flowId = [socket hash];
    flow.server = server;
    flow.dnsRequest = dnsRequest;
    flow.socket = socket;
    flow.complete = complete;
    [self setFlow:flow withId:flow.flowId];
    
    [socket sendData:requestData toHost:server port:kDnsPort withTimeout:self.timeout tag:flow.flowId];
}

- (void)udpSocketComplete:(QNAsyncUdpSocket *)sock data:(NSData *)data error:(NSError * _Nullable)error {
    [sock close];
    
    QNDnsFlow *flow = [self getFlowWithId:[sock hash]];
    if (!flow) {
        return;
    }
    [self removeFlowWithId:flow.flowId];
    
    if (error != nil) {
        flow.complete(nil, error);
    } else if (data != nil) {
        NSError *err = nil;
        QNDnsResponse *response = [QNDnsResponse dnsResponse:flow.server source:QNRecordSourceUdp request:flow.dnsRequest dnsRecordData:data error:&err];
        flow.complete(response, err);
    } else {
        flow.complete(nil, nil);
    }
}

//MARK: -- QNAsyncUdpSocketDelegate
- (void)udpSocket:(QNAsyncUdpSocket *)sock didConnectToAddress:(NSData *)address {
}

- (void)udpSocket:(QNAsyncUdpSocket *)sock didNotConnect:(NSError * _Nullable)error {
    [self udpSocketComplete:sock data:nil error:error];
}

- (void)udpSocket:(QNAsyncUdpSocket *)sock didSendDataWithTag:(long)tag {
}

- (void)udpSocket:(QNAsyncUdpSocket *)sock didNotSendDataWithTag:(long)tag dueToError:(NSError * _Nullable)error {
    [self udpSocketComplete:sock data:nil error:error];
}

- (void)udpSocket:(QNAsyncUdpSocket *)sock
   didReceiveData:(NSData *)data
      fromAddress:(NSData *)address
withFilterContext:(nullable id)filterContext {
    [self udpSocketComplete:sock data:data error:nil];
}

- (void)udpSocketDidClose:(QNAsyncUdpSocket *)sock withError:(NSError  * _Nullable)error {
    [self udpSocketComplete:sock data:nil error:error];
}


//MARK: flows
- (QNDnsFlow *)getFlowWithId:(long)flowId {
    NSString *key = [NSString stringWithFormat:@"%ld", flowId];
    QNDnsFlow *flow = nil;
    @synchronized (self) {
        flow = self.flows[key];
    }
    return flow;
}

- (BOOL)setFlow:(QNDnsFlow *)flow withId:(long)flowId {
    if (flow == nil) {
        return false;
    }
    
    NSString *key = [NSString stringWithFormat:@"%ld", flowId];
    @synchronized (self) {
        self.flows[key] = flow;
    }
    return true;
}

- (void)removeFlowWithId:(long)flowId {
    NSString *key = [NSString stringWithFormat:@"%ld", flowId];
    @synchronized (self) {
        [self.flows removeObjectForKey:key];
    }
}

- (long)refreshPort {
    return arc4random()%(kMaxPort + kMinPort) - kMinPort;
}

@end
