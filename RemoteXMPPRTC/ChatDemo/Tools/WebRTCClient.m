//
//  WebRTCClient.m
//  ChatDemo
//
//  Created by Harvey on 16/5/30.
//  Copyright © 2016年 Mac. All rights reserved.
//
#import <AVFoundation/AVFoundation.h>
#import <CoreTelephony/CTCallCenter.h>
#import <CoreTelephony/CTCall.h>

#import "WebRTCClient.h"
#import "RTCContants.h"
#import "HLIMClient.h"
#import "HLIMCenter.h"

#import "RTCICEServer.h"
#import "RTCICECandidate.h"
#import "RTCICEServer.h"
#import "RTCMediaConstraints.h"
#import "RTCMediaStream.h"
#import "RTCPair.h"
#import "RTCPeerConnection.h"
#import "RTCPeerConnectionDelegate.h"
#import "RTCPeerConnectionFactory.h"
#import "RTCSessionDescription.h"
#import "RTCVideoRenderer.h"
#import "RTCVideoCapturer.h"
#import "RTCVideoTrack.h"
#import "RTCAVFoundationVideoSource.h"
#import "RTCSessionDescriptionDelegate.h"
#import "RTCEAGLVideoView.h"

@interface WebRTCClient ()<RTCPeerConnectionDelegate,RTCSessionDescriptionDelegate,RTCEAGLVideoViewDelegate>

@property (strong, nonatomic)   RTCPeerConnectionFactory            *peerConnectionFactory;
@property (nonatomic, strong)   RTCMediaConstraints                 *pcConstraints;
@property (nonatomic, strong)   RTCMediaConstraints                 *sdpConstraints;
@property (nonatomic, strong)   RTCMediaConstraints                 *videoConstraints;
@property (nonatomic, strong)   RTCPeerConnection                   *peerConnection;

@property (nonatomic, strong)   RTCEAGLVideoView                    *localVideoView;
@property (nonatomic, strong)   RTCEAGLVideoView                    *remoteVideoView;
@property (nonatomic, strong)   RTCVideoTrack                       *localVideoTrack;
@property (nonatomic, strong)   RTCVideoTrack                       *remoteVideoTrack;

@property (assign, nonatomic)   ARDSignalingChannelState             sinalingChannelState;  /**< 信令通道的状态 */

@property (strong, nonatomic)   AVAudioPlayer               *audioPlayer;  /**< 音频播放器 */
@property (nonatomic, strong)   CTCallCenter                *callCenter;

@property (strong, nonatomic)   NSMutableArray              *ICEServers;

@property (strong, nonatomic)   NSMutableArray              *messages;  /**< 信令消息队列 */

@property (assign, nonatomic)   BOOL                        initiator;  /**< 是否是发起方 */

@property (assign, nonatomic)   BOOL                        hasReceivedSdp;  /**< 已经收到SDP信息 */


@end

@implementation WebRTCClient

static WebRTCClient *instance = nil;

+ (instancetype)sharedInstance
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[[self class] alloc] init];
        instance.ICEServers = [NSMutableArray arrayWithObject:[instance defaultSTUNServer]];
        instance.messages = [NSMutableArray array];
        
        [instance addNotifications];
    });
    return instance;
}

+ (NSString *)randomRoomId
{
    unsigned int roomId = arc4random_uniform(1000000001);
    NSString *roomIdStr = [NSString stringWithFormat:@"%06u",roomId];
    
    return roomIdStr;
}

- (void)addNotifications
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(hangupEvent) name:kHangUpNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receiveSignalingMessage:) name:kReceivedSinalingMessageNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(acceptAction) name:kAcceptNotification object:nil];
}

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [super allocWithZone:zone];
    });
    return instance;
}


- (RTCICEServer *)defaultSTUNServer {
    NSURL *defaultSTUNServerURL = [NSURL URLWithString:RTCSTUNServerURL];
    return [[RTCICEServer alloc] initWithURI:defaultSTUNServerURL
                                    username:@""
                                    password:@""];
}

- (void)startEngine
{
    [RTCPeerConnectionFactory initializeSSL];
    //set RTCPeerConnection's constraints
    self.peerConnectionFactory = [[RTCPeerConnectionFactory alloc] init];
    NSArray *mandatoryConstraints = @[[[RTCPair alloc] initWithKey:@"OfferToReceiveAudio" value:@"true"],
                                      [[RTCPair alloc] initWithKey:@"OfferToReceiveVideo" value:@"true"]
                                      ];
    NSArray *optionalConstraints = @[[[RTCPair alloc] initWithKey:@"DtlsSrtpKeyAgreement" value:@"false"]];
//    NSArray *optionalConstraints = @[[[RTCPair alloc] initWithKey:@"DtlsSrtpKeyAgreement" value:@"true"]];
    self.pcConstraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:mandatoryConstraints optionalConstraints:optionalConstraints];
    
    //set SDP's Constraints in order to (offer/answer)
    NSArray *sdpMandatoryConstraints = @[[[RTCPair alloc] initWithKey:@"OfferToReceiveAudio" value:@"true"],
                                         [[RTCPair alloc] initWithKey:@"OfferToReceiveVideo" value:@"true"]
                                         ];
    self.sdpConstraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:sdpMandatoryConstraints optionalConstraints:nil];
    
    //set RTCVideoSource's(localVideoSource) constraints
    self.videoConstraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
}

- (void)stopEngine
{
    [RTCPeerConnectionFactory deinitializeSSL];
    
    _peerConnectionFactory = nil;
}

- (void)showRTCViewByRemoteName:(NSString *)remoteName isVideo:(BOOL)isVideo isCaller:(BOOL)isCaller
{
    // 1.显示视图
    self.rtcView = [[RTCView alloc] initWithIsVideo:isVideo isCallee:!isCaller];
    self.rtcView.nickName = remoteName;
    self.rtcView.connectText = @"等待对方接听";
    self.rtcView.netTipText = @"网络状况良好";
    [self.rtcView show];
    
    // 2.播放声音
    NSURL *audioURL;
    if (isCaller) {
        audioURL = [[NSBundle mainBundle] URLForResource:@"AVChat_waitingForAnswer.mp3" withExtension:nil];
    } else {
        audioURL = [[NSBundle mainBundle] URLForResource:@"AVChat_incoming.mp3" withExtension:nil];
    }
    _audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:audioURL error:nil];
    _audioPlayer.numberOfLoops = -1;
    [_audioPlayer prepareToPlay];
    [_audioPlayer play];
    
    // 3.拨打时，禁止黑屏
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    
    // 4.监听系统电话
    [self listenSystemCall];
    
    // 5.做RTC必要设置
    if (isCaller) {
        // 如果是发起者
        self.initiator = YES;
        // 1.创建一个房间号
        NSString *roomId = [WebRTCClient randomRoomId];
        
        // 2.注册该房间，并加入到该房间
        [self requestRoomServerWithURL:RTCRoomServerURL roomId:roomId completionHandler:^(NSDictionary *dict, BOOL success) {
            if (!success) {
                NSLog(@"加入房间失败咯");
                return ;
            }
            
            NSLog(@"%@加入房间成功返回的参数：%@",[NSThread currentThread], dict);
            self.roomId = dict[kARDJoinRoomIdKey];
            self.clientId = dict[kARDJoinClientIdKey];
            self.initiator = [dict[kARDJoinInitiatorKey] boolValue];
            
            [self initRTCSetting];
            // 创建一个offer信令
            [self.peerConnection createOfferWithDelegate:self constraints:self.sdpConstraints];
        }];
        
    } else {
        self.initiator = NO;
        // 如果是接收者，就要处理信令信息，创建一个answer
        NSLog(@"如果是接收者，就要处理信令信息");
        self.rtcView.connectText = isVideo ? @"视频通话":@"语音通话";
        // 2.注册该房间，并加入到该房间
        [self requestRoomServerWithURL:RTCRoomServerURL roomId:self.roomId completionHandler:^(NSDictionary *dict, BOOL success) {
            if (!success) {
                NSLog(@"加入房间失败咯");
                return ;
            }
            NSLog(@"成功之后的参数：%@",dict);
            self.roomId = dict[kARDJoinRoomIdKey];
            self.clientId = dict[kARDJoinClientIdKey];
            for (NSString *messageStr in dict[kARDJoinMessagesKey]) {
                NSData *data = [messageStr dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *messageDict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                [self handleSignalingMessage:messageDict];
            }
        
        }];
    }
}

/**
 *  关于RTC 的设置
 */
- (void)initRTCSetting
{
    //添加 turn 服务器
//    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:RTCTRUNServerURL]];
//    [request addValue:@"Mozilla/5.0" forHTTPHeaderField:@"user-agent"];
//    [request addValue:RTCRoomServerURL forHTTPHeaderField:@"origin"];
//    [request setTimeoutInterval:5];
//    [request setCachePolicy:NSURLRequestReloadIgnoringCacheData];
//    
//    NSURLSessionDataTask *turnTask = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
//        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
//        NSLog(@"返回的服务器：%@",dict);
//        NSString *username = dict[@"username"];
//        NSString *password = dict[@"password"];
//        NSArray *uris = dict[@"uris"];
//        
//        for (NSString *uri in uris) {
//            RTCICEServer *server = [[RTCICEServer alloc] initWithURI:[NSURL URLWithString:uri] username:username password:password];
//            [_ICEServers addObject:server];
//        }
//        
//    }];
//    [turnTask resume];
    
    self.peerConnection = [self.peerConnectionFactory peerConnectionWithICEServers:_ICEServers constraints:self.pcConstraints delegate:self];
    
    //设置 local media stream
    RTCMediaStream *mediaStream = [self.peerConnectionFactory mediaStreamWithLabel:@"ARDAMS"];
    // 添加 local video track
    RTCAVFoundationVideoSource *source = [[RTCAVFoundationVideoSource alloc] initWithFactory:self.peerConnectionFactory constraints:self.videoConstraints];
    RTCVideoTrack *localVideoTrack = [[RTCVideoTrack alloc] initWithFactory:self.peerConnectionFactory source:source trackId:@"AVAMSv0"];
    [mediaStream addVideoTrack:localVideoTrack];
    self.localVideoTrack = localVideoTrack;
    
    // 添加 local audio track
    RTCAudioTrack *localAudioTrack = [self.peerConnectionFactory audioTrackWithID:@"ARDAMSa0"];
    [mediaStream addAudioTrack:localAudioTrack];
    // 添加 mediaStream
    [self.peerConnection addStream:mediaStream];
    
    RTCEAGLVideoView *localVideoView = [[RTCEAGLVideoView alloc] initWithFrame:self.rtcView.ownImageView.bounds];
    localVideoView.transform = CGAffineTransformMakeScale(-1, 1);
    localVideoView.delegate = self;
    [self.rtcView.ownImageView addSubview:localVideoView];
    self.localVideoView = localVideoView;
    
    [self.localVideoTrack addRenderer:self.localVideoView];
    
    RTCEAGLVideoView *remoteVideoView = [[RTCEAGLVideoView alloc] initWithFrame:self.rtcView.adverseImageView.bounds];
    remoteVideoView.transform = CGAffineTransformMakeScale(-1, 1);
    remoteVideoView.delegate = self;
    [self.rtcView.adverseImageView addSubview:remoteVideoView];
    self.remoteVideoView = remoteVideoView;
}

- (void)cleanCache
{
    // 1.将试图置为nil
    self.rtcView = nil;
    
    // 2.将音乐停止
    if ([_audioPlayer isPlaying]) {
        [_audioPlayer stop];
    }
    _audioPlayer = nil;
    
    // 3.取消手机常亮
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    
    // 4.取消系统电话监听
    self.callCenter = nil;
    
    _peerConnection = nil;
    _localVideoTrack = nil;
    _remoteVideoTrack = nil;
    _localVideoView = nil;
    _remoteVideoView = nil;
    _hasReceivedSdp = NO;
}

- (void)listenSystemCall
{
    self.callCenter = [[CTCallCenter alloc] init];
    self.callCenter.callEventHandler = ^(CTCall* call) {
        if ([call.callState isEqualToString:CTCallStateDisconnected])
        {
            NSLog(@"Call has been disconnected");
        }
        else if ([call.callState isEqualToString:CTCallStateConnected])
        {
            NSLog(@"Call has just been connected");
        }
        else if([call.callState isEqualToString:CTCallStateIncoming])
        {
            NSLog(@"Call is incoming");
        }
        else if ([call.callState isEqualToString:CTCallStateDialing])
        {
            NSLog(@"call is dialing");
        }
        else
        {
            NSLog(@"Nothing is done");
        }
    };
}

- (void)resizeViews
{
    [self videoView:self.localVideoView didChangeVideoSize:self.rtcView.ownImageView.bounds.size];
    [self videoView:self.remoteVideoView didChangeVideoSize:self.rtcView.adverseImageView.bounds.size];
}


/**
 *  在服务器端创建房间
 *
 *  @param URL               房间服务器地址
 *  @param roomId            房间号
 *  @param completionHandler 完成后回调
 */
- (void)requestRoomServerWithURL:(NSString *)URL roomId:(NSString *)roomId completionHandler:(void (^)(NSDictionary *dict, BOOL success))completionHandler
{
    NSString *fullStr = [NSString stringWithFormat:@"%@/join/%@",URL,roomId];
    NSURL *fullURL = [NSURL URLWithString:fullStr];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:fullURL];
    request.HTTPMethod = @"POST";
    
    NSURLSessionDataTask *registTask = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) {
            NSLog(@"在服务器上创建房间失败");
            if (completionHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(nil, NO);
                });
            }
            return;
        }
        
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:nil];
        if (!dict) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, NO);
            });
            return;
        }
//        NSLog(@"注册房间返回的结果：%@",dict);
        NSString *result = dict[kARDJoinResultKey];
        
        NSDictionary *params = dict[kARDJoinResultParamsKey];
        
        id initiator = params[kARDJoinInitiatorKey];
        NSString *roomId = params[kARDJoinRoomIdKey];
        NSString *clientId = params[kARDJoinClientIdKey];
        
        NSArray *messages = params[kARDJoinMessagesKey];
        
        NSString *webSocketURL = params[kARDJoinWebSocketURLKey];
        NSString *webSocketRestURL = params[kARDJoinWebSocketRestURLKey];
        
        NSMutableDictionary *handleDict = [NSMutableDictionary dictionary];
        if (result) {
            [handleDict setObject:result forKey:kARDJoinResultKey];
        }
        if (initiator) {
            [handleDict setObject:initiator forKey:kARDJoinInitiatorKey];
        }
        if (roomId) {
            [handleDict setObject:roomId forKey:kARDJoinRoomIdKey];
        }
        if (clientId) {
            [handleDict setObject:clientId forKey:kARDJoinClientIdKey];
        }
        if (messages) {
            [handleDict setObject:messages forKey:kARDJoinMessagesKey];
        }
        if (webSocketURL) {
            [handleDict setObject:webSocketURL forKey:kARDJoinWebSocketURLKey];
        }
        if (webSocketRestURL) {
            [handleDict setObject:webSocketRestURL forKey:kARDJoinWebSocketRestURLKey];
        }
        
        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(handleDict, YES);
            });
        }
    }];
                                        
    [registTask resume];
}

- (void)registWithRoomId:(NSString *)roomId clientId:(NSString *)clientId completionHandle:(void (^)(NSDictionary *dict))completionHandle
{
    NSString *registURL = [NSString stringWithFormat:@"%@/%@/%@",RTCRoomServerURL,roomId,clientId];
    NSURL *fullURL = [NSURL URLWithString:registURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:fullURL];
    request.HTTPMethod = @"POST";
    
    NSURLSessionDataTask *registTask = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) {
            NSLog(@"失败");
            if (completionHandle) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandle(nil);
                });
            }
            return;
        }
        NSLog(@"%@",httpResponse);
        
    }];
    
    [registTask resume];
}

- (RTCSessionDescription *)descriptionWithDescription:(RTCSessionDescription *)description videoFormat:(NSString *)videoFormat
{
    NSString *sdpString = description.description;
    NSString *lineChar = @"\n";
    NSMutableArray *lines = [NSMutableArray arrayWithArray:[sdpString componentsSeparatedByString:lineChar]];
    NSInteger mLineIndex = -1;
    NSString *videoFormatRtpMap = nil;
    NSString *pattern = [NSString stringWithFormat:@"^a=rtpmap:(\\d+) %@(/\\d+)+[\r]?$", videoFormat];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    for (int i = 0; (i < lines.count) && (mLineIndex == -1 || !videoFormatRtpMap); ++i) {
        // mLineIndex 和 videoFromatRtpMap 都更新了之后跳出循环
        NSString *line = lines[i];
        if ([line hasPrefix:@"m=video"]) {
            mLineIndex = i;
            continue;
        }
        
        NSTextCheckingResult *result = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (result) {
            videoFormatRtpMap = [line substringWithRange:[result rangeAtIndex:1]];
            continue;
        }
    }
    
    if (mLineIndex == -1) {
        // 没有m = video line, 所以不能转格式,所以返回原来的description
        return description;
    }
    
    if (!videoFormatRtpMap) {
        // 没有videoFormat 类型的rtpmap。
        return description;
    }
    
    NSString *spaceChar = @" ";
    NSArray *origSpaceLineParts = [lines[mLineIndex] componentsSeparatedByString:spaceChar];
    if (origSpaceLineParts.count > 3) {
        NSMutableArray *newMLineParts = [NSMutableArray arrayWithCapacity:origSpaceLineParts.count];
        NSInteger origPartIndex = 0;
        
        [newMLineParts addObject:origSpaceLineParts[origPartIndex++]];
        [newMLineParts addObject:origSpaceLineParts[origPartIndex++]];
        [newMLineParts addObject:origSpaceLineParts[origPartIndex++]];
        [newMLineParts addObject:videoFormatRtpMap];
        for (; origPartIndex < origSpaceLineParts.count; ++origPartIndex) {
            if (![videoFormatRtpMap isEqualToString:origSpaceLineParts[origPartIndex]]) {
                [newMLineParts addObject:origSpaceLineParts[origPartIndex]];
            }
        }
        
        NSString *newMLine = [newMLineParts componentsJoinedByString:spaceChar];
        [lines replaceObjectAtIndex:mLineIndex withObject:newMLine];
    } else {
        NSLog(@"SDP Media description 格式 错误");
    }
    NSString *mangledSDPString = [lines componentsJoinedByString:lineChar];
    
    return [[RTCSessionDescription alloc] initWithType:description.type sdp:mangledSDPString];
}

#pragma mark - notification events
- (void)hangupEvent
{
    NSDictionary *dict = @{@"type":@"bye"};
    [self processMessageDict:dict];
}

- (void)receiveSignalingMessage:(NSNotification *)notification
{
    NSDictionary *dict = [notification object];
    [self handleSignalingMessage:dict];
    
    [self drainMessages];
}

- (void)handleSignalingMessage:(NSDictionary *)dict
{
    NSString *type = dict[@"type"];
    if ([type isEqualToString:@"offer"] || [type isEqualToString:@"answer"]) {
        [self.messages insertObject:dict atIndex:0];
        _hasReceivedSdp = YES;
        
    } else if ([type isEqualToString:@"candidate"]) {
        
        [self.messages addObject:dict];
    } else if ([type isEqualToString:@"bye"]) {
        [self processMessageDict:dict];
    }
}

- (void)drainMessages
{
    if (!_peerConnection || !_hasReceivedSdp) {
        return;
    }
    
    for (NSDictionary *dict in self.messages) {
        [self processMessageDict:dict];
    }
    
    [self.messages removeAllObjects];
}

- (void)acceptAction
{
    [self.audioPlayer stop];
    
    [self initRTCSetting];
    
    [self drainMessages];
}

- (void)processMessageDict:(NSDictionary *)dict
{
    NSString *type = dict[@"type"];
    if ([type isEqualToString:@"offer"]) {
        RTCSessionDescription *remoteSdp = [[RTCSessionDescription alloc] initWithType:type sdp:dict[@"sdp"]];
        
        [self.peerConnection setRemoteDescriptionWithDelegate:self sessionDescription:remoteSdp];
        
        [self.peerConnection createAnswerWithDelegate:self constraints:self.sdpConstraints];
    } else if ([type isEqualToString:@"answer"]) {
        RTCSessionDescription *remoteSdp = [[RTCSessionDescription alloc] initWithType:type sdp:dict[@"sdp"]];
        
        [self.peerConnection setRemoteDescriptionWithDelegate:self sessionDescription:remoteSdp];
        
    } else if ([type isEqualToString:@"candidate"]) {
        NSString *mid = [dict objectForKey:@"id"];
        NSNumber *sdpLineIndex = [dict objectForKey:@"label"];
        NSString *sdp = [dict objectForKey:@"sdp"];
        RTCICECandidate *candidate = [[RTCICECandidate alloc] initWithMid:mid index:sdpLineIndex.intValue sdp:sdp];

        [self.peerConnection addICECandidate:candidate];
    } else if ([type isEqualToString:@"bye"]) {

        if (self.rtcView) {
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
            NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
            if (jsonStr.length > 0) {
                [[HLIMClient shareClient] sendSignalingMessage:jsonStr toUser:self.remoteJID];
            }
            
            [self.rtcView dismiss];
            
            [self cleanCache];
        }
    }
}

#pragma mark - RTCPeerConnectionDelegate
// Triggered when the SignalingState changed.
- (void)peerConnection:(RTCPeerConnection *)peerConnection
 signalingStateChanged:(RTCSignalingState)stateChanged
{
    NSLog(@"信令状态改变");
    switch (stateChanged) {
        case RTCSignalingStable:
        {
            NSLog(@"stateChanged = RTCSignalingStable");
        }
            break;
        case RTCSignalingClosed:
        {
            NSLog(@"stateChanged = RTCSignalingClosed");
        }
            break;
        case RTCSignalingHaveLocalOffer:
        {
            NSLog(@"stateChanged = RTCSignalingHaveLocalOffer");
        }
            break;
        case RTCSignalingHaveRemoteOffer:
        {
            NSLog(@"stateChanged = RTCSignalingHaveRemoteOffer");
        }
            break;
        case RTCSignalingHaveRemotePrAnswer:
        {
            NSLog(@"stateChanged = RTCSignalingHaveRemotePrAnswer");
        }
            break;
        case RTCSignalingHaveLocalPrAnswer:
        {
            NSLog(@"stateChanged = RTCSignalingHaveLocalPrAnswer");
        }
            break;
    }

}

// Triggered when media is received on a new stream from remote peer.
- (void)peerConnection:(RTCPeerConnection *)peerConnection
           addedStream:(RTCMediaStream *)stream
{
    NSLog(@"已添加多媒体流");
    NSLog(@"Received %lu video tracks and %lu audio tracks",
          (unsigned long)stream.videoTracks.count,
          (unsigned long)stream.audioTracks.count);
    if ([stream.videoTracks count]) {
        self.remoteVideoTrack = nil;
        [self.remoteVideoView renderFrame:nil];
        self.remoteVideoTrack = stream.videoTracks[0];
        [self.remoteVideoTrack addRenderer:self.remoteVideoView];
    }
    
    [self videoView:self.remoteVideoView didChangeVideoSize:self.rtcView.adverseImageView.bounds.size];
    [self videoView:self.localVideoView didChangeVideoSize:self.rtcView.ownImageView.bounds.size];
}

// Triggered when a remote peer close a stream.
- (void)peerConnection:(RTCPeerConnection *)peerConnection
         removedStream:(RTCMediaStream *)stream
{
    NSLog(@"a remote peer close a stream");
}

// Triggered when renegotiation is needed, for example the ICE has restarted.
- (void)peerConnectionOnRenegotiationNeeded:(RTCPeerConnection *)peerConnection
{
    NSLog(@"Triggered when renegotiation is needed");
}

// Called any time the ICEConnectionState changes.
- (void)peerConnection:(RTCPeerConnection *)peerConnection
  iceConnectionChanged:(RTCICEConnectionState)newState
{
    NSLog(@"%s",__func__);
    switch (newState) {
        case RTCICEConnectionNew:
        {
            NSLog(@"newState = RTCICEConnectionNew");
        }
            break;
        case RTCICEConnectionChecking:
        {
            NSLog(@"newState = RTCICEConnectionChecking");
        }
            break;
        case RTCICEConnectionConnected:
        {
            NSLog(@"newState = RTCICEConnectionConnected");
        }
            break;
        case RTCICEConnectionCompleted:
        {
            NSLog(@"newState = RTCICEConnectionCompleted");
        }
            break;
        case RTCICEConnectionFailed:
        {
            NSLog(@"newState = RTCICEConnectionFailed");
        }
            break;
        case RTCICEConnectionDisconnected:
        {
            NSLog(@"newState = RTCICEConnectionDisconnected");
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.rtcView dismiss];
                
                [self cleanCache];
            });
        }
            break;
        case RTCICEConnectionClosed:
        {
            NSLog(@"newState = RTCICEConnectionClosed");
        }
            break;
        case RTCICEConnectionMax:
        {
            NSLog(@"newState = RTCICEConnectionMax");
        }
            break;
    }
}

// Called any time the ICEGatheringState changes.
- (void)peerConnection:(RTCPeerConnection *)peerConnection
   iceGatheringChanged:(RTCICEGatheringState)newState
{
    NSLog(@"%s",__func__);
    switch (newState) {
        case RTCICEGatheringNew:
        {
            NSLog(@"newState = RTCICEGatheringNew");
        }
            break;
        case RTCICEGatheringGathering:
        {
            NSLog(@"newState = RTCICEGatheringGathering");
        }
            break;
        case RTCICEGatheringComplete:
        {
            NSLog(@"newState = RTCICEGatheringComplete");
        }
            break;
    }

}

// New Ice candidate have been found.
- (void)peerConnection:(RTCPeerConnection *)peerConnection
       gotICECandidate:(RTCICECandidate *)candidate
{
    NSLog(@"新的 Ice candidate 被发现.");
    
    NSDictionary *jsonDict = @{@"type":@"candidate",
                               @"label":[NSNumber numberWithInteger:candidate.sdpMLineIndex],
                               @"id":candidate.sdpMid,
                               @"sdp":candidate.sdp
                               };
    NSLog(@"jsonDict:%@",jsonDict);
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonDict options:0 error:nil];
    if (jsonData.length > 0) {
        NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        [[HLIMClient shareClient] sendSignalingMessage:jsonStr toUser:self.remoteJID];
    }
}

// New data channel has been opened.
- (void)peerConnection:(RTCPeerConnection*)peerConnection
    didOpenDataChannel:(RTCDataChannel*)dataChannel
{
    NSLog(@"New data channel has been opened.");
}

#pragma mark - RTCSessionDescriptionDelegate
// Called when creating a session.
- (void)peerConnection:(RTCPeerConnection *)peerConnection
didCreateSessionDescription:(RTCSessionDescription *)sdp
                 error:(NSError *)error
{
    if (error) {
        NSLog(@"创建SessionDescription 失败");
#warning 这里创建 创建SessionDescription 失败
    } else {
        NSLog(@"创建SessionDescription 成功");
        RTCSessionDescription *sdpH264 = [self descriptionWithDescription:sdp videoFormat:@"H264"];
        [self.peerConnection setLocalDescriptionWithDelegate:self sessionDescription:sdpH264];
        
        if ([sdp.type isEqualToString:@"offer"]) {
            NSDictionary *dict = @{@"roomId":self.roomId};
            NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
            NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            
            [[HLIMClient shareClient] sendSignalingMessage:message toUser:self.remoteJID];
        }
        
        NSDictionary *jsonDict = @{ @"type" : sdp.type, @"sdp" : sdp.description };
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonDict options:0 error:nil];
        NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        
        [[HLIMClient shareClient] sendSignalingMessage:jsonStr toUser:self.remoteJID];
    }
}

// Called when setting a local or remote description.
- (void)peerConnection:(RTCPeerConnection *)peerConnection
didSetSessionDescriptionWithError:(NSError *)error
{
    NSLog(@"%s",__func__);
    
    if (error) {
        NSLog(@"设置SessionDescription失败");
        return;
    }
    
}

#pragma mark - RTCEAGLVideoViewDelegate
- (void)videoView:(RTCEAGLVideoView*)videoView didChangeVideoSize:(CGSize)size
{
    if (videoView == self.localVideoView) {
        
        NSLog(@"local size === %@",NSStringFromCGSize(size));
    }else if (videoView == self.remoteVideoView){
        NSLog(@"remote size === %@",NSStringFromCGSize(size));
    }
}

@end
