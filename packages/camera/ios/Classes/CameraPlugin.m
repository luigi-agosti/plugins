#import "CameraPlugin.h"
#import <AVFoundation/AVFoundation.h>
#import <libkern/OSAtomic.h>

@interface NSError (FlutterError)
@property(readonly, nonatomic) FlutterError *flutterError;
@end

@implementation NSError (FlutterError)
- (FlutterError *)flutterError {
  return [FlutterError errorWithCode:[NSString stringWithFormat:@"Error %d", (int)self.code]
                             message:self.domain
                             details:self.localizedDescription];
}
@end

@interface FLTSavePhotoDelegate : NSObject<AVCapturePhotoCaptureDelegate>
@property(readonly, nonatomic) NSString *path;
@property(readonly, nonatomic) FlutterResult result;

- initWithPath:(NSString *)filename result:(FlutterResult)result;
@end

@implementation FLTSavePhotoDelegate {
  /// Used to keep the delegate alive until didFinishProcessingPhotoSampleBuffer.
  FLTSavePhotoDelegate *selfReference;
}

- initWithPath:(NSString *)path result:(FlutterResult)result {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _path = path;
  _result = result;
  selfReference = self;
  return self;
}

- (void)captureOutput:(AVCapturePhotoOutput *)output
    didFinishProcessingPhotoSampleBuffer:(CMSampleBufferRef)photoSampleBuffer
                previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer
                        resolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings
                         bracketSettings:(AVCaptureBracketedStillImageSettings *)bracketSettings
                                   error:(NSError *)error {
  selfReference = nil;
  if (error) {
    _result([error flutterError]);
    return;
  }
  NSData *data = [AVCapturePhotoOutput
      JPEGPhotoDataRepresentationForJPEGSampleBuffer:photoSampleBuffer
                            previewPhotoSampleBuffer:previewPhotoSampleBuffer];
  // TODO(sigurdm): Consider writing file asynchronously.
  bool success = [data writeToFile:_path atomically:YES];
  if (!success) {
    _result([FlutterError errorWithCode:@"IOError" message:@"Unable to write file" details:nil]);
    return;
  }
  _result(nil);
}
@end

@interface FLTCam : NSObject<FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate,
                             AVCaptureAudioDataOutputSampleBufferDelegate, FlutterStreamHandler>
@property(readonly, nonatomic) int64_t textureId;
@property(nonatomic, copy) void (^onFrameAvailable)();
@property(nonatomic) FlutterEventChannel *eventChannel;
@property(nonatomic) FlutterEventSink eventSink;
@property(readonly, nonatomic) AVCaptureSession *captureSession;
@property(readonly, nonatomic) AVCaptureDevice *captureDevice;
@property(readonly, nonatomic) AVCapturePhotoOutput *capturePhotoOutput;
@property(readonly, nonatomic) AVCaptureVideoDataOutput *captureVideoOutput;
@property(readonly, nonatomic) AVCaptureInput *captureVideoInput;
@property(readonly) CVPixelBufferRef volatile latestPixelBuffer;
@property(readonly, nonatomic) CGSize previewSize;
@property(readonly, nonatomic) CGSize captureSize;
@property(strong, nonatomic) AVAssetWriter *videoWriter;
@property(strong, nonatomic) AVAssetWriterInput *videoWriterInput;
@property(strong, nonatomic) AVAssetWriterInput *audioWriterInput;
@property(strong, nonatomic) AVAssetWriterInputPixelBufferAdaptor *assetWriterPixelBufferAdaptor;
@property(strong, nonatomic) AVCaptureVideoDataOutput *videoOutput;
@property(strong, nonatomic) AVCaptureAudioDataOutput *audioOutput;
@property(assign, nonatomic) BOOL isRecording;
@property(assign, nonatomic) BOOL isAudioSetup;
- (instancetype)initWithCameraName:(NSString *)cameraName
                  resolutionPreset:(NSString *)resolutionPreset
                             error:(NSError **)error;
- (void)start;
- (void)stop;
- (void)startRecordingVideoAtPath:(NSString *)path result:(FlutterResult)result;
- (void)stopRecordingVideoWithResult:(FlutterResult)result;
- (void)captureToFile:(NSString *)filename result:(FlutterResult)result;
@end

@implementation FLTCam
- (instancetype)initWithCameraName:(NSString *)cameraName
                  resolutionPreset:(NSString *)resolutionPreset
                             error:(NSError **)error {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _captureSession = [[AVCaptureSession alloc] init];
  AVCaptureSessionPreset preset;
  if ([resolutionPreset isEqualToString:@"high"]) {
    preset = AVCaptureSessionPresetHigh;
  } else if ([resolutionPreset isEqualToString:@"medium"]) {
    preset = AVCaptureSessionPresetMedium;
  } else {
    NSAssert([resolutionPreset isEqualToString:@"low"], @"Unknown resolution preset %@",
             resolutionPreset);
    preset = AVCaptureSessionPresetLow;
  }
  _captureSession.sessionPreset = preset;
  _captureDevice = [AVCaptureDevice deviceWithUniqueID:cameraName];
  NSError *localError = nil;
  _captureVideoInput =
      [AVCaptureDeviceInput deviceInputWithDevice:_captureDevice error:&localError];
  if (localError) {
    *error = localError;
    return nil;
  }
  CMVideoDimensions dimensions =
      CMVideoFormatDescriptionGetDimensions([[_captureDevice activeFormat] formatDescription]);
  _previewSize = CGSizeMake(dimensions.width, dimensions.height);

  _captureVideoOutput = [AVCaptureVideoDataOutput new];
  _captureVideoOutput.videoSettings =
      @{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
  [_captureVideoOutput setAlwaysDiscardsLateVideoFrames:YES];
  [_captureVideoOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];

  AVCaptureConnection *connection =
      [AVCaptureConnection connectionWithInputPorts:_captureVideoInput.ports
                                             output:_captureVideoOutput];
  if ([_captureDevice position] == AVCaptureDevicePositionFront) {
    connection.videoMirrored = YES;
  }
  connection.videoOrientation = AVCaptureVideoOrientationPortrait;
  [_captureSession addInputWithNoConnections:_captureVideoInput];
  [_captureSession addOutputWithNoConnections:_captureVideoOutput];
  [_captureSession addConnection:connection];
  _capturePhotoOutput = [AVCapturePhotoOutput new];
  [_captureSession addOutput:_capturePhotoOutput];

    _messageCodec = [FlutterStandardMessageCodec sharedInstance];
  return self;
}

- (void)start {
  [_captureSession startRunning];
}

- (void)stop {
  [_captureSession stopRunning];
}

- (void)captureToFile:(NSString *)path result:(FlutterResult)result {
  AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
  [_capturePhotoOutput
      capturePhotoWithSettings:settings
                      delegate:[[FLTSavePhotoDelegate alloc] initWithPath:path result:result]];
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
  if (output == _captureVideoOutput) {
    CVPixelBufferRef newBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CFRetain(newBuffer);
    CVPixelBufferRef old = _latestPixelBuffer;
    while (!OSAtomicCompareAndSwapPtrBarrier(old, newBuffer, (void **)&_latestPixelBuffer)) {
      old = _latestPixelBuffer;
    }
    if (old != nil) {
      CFRelease(old);
    }
    if (_onFrameAvailable) {
      _onFrameAvailable();
    }
  }
  if (!CMSampleBufferDataIsReady(sampleBuffer)) {
      _eventSink([NSString stringWithFormat:@"sample buffer is not ready. Skipping sample"]);
    return;
  }
  if (_isRecording == YES) {
    CMTime lastSampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (_videoWriter.status != AVAssetWriterStatusWriting) {
      [_videoWriter startWriting];
      [_videoWriter startSessionAtSourceTime:lastSampleTime];
    }
    if (output == _captureVideoOutput) {
      [self newVideoSample:sampleBuffer];
    } else {
      [self newAudioSample:sampleBuffer];
    }
  }
}

- (void)newVideoSample:(CMSampleBufferRef)sampleBuffer {
    if (_videoWriter.status > AVAssetWriterStatusWriting) {
      if (_videoWriter.status == AVAssetWriterStatusFailed)
          _eventSink([NSString stringWithFormat:@"AVAssetWriter Failed"]);
      return;
    }
    if (![_videoWriterInput appendSampleBuffer:sampleBuffer]) {
        _eventSink([NSString stringWithFormat:@"Unable to write to video input"]);
    }
}

- (void)newAudioSample:(CMSampleBufferRef)sampleBuffer {
    if (_videoWriter.status > AVAssetWriterStatusWriting) {
      if (_videoWriter.status == AVAssetWriterStatusFailed)
          _eventSink([NSString stringWithFormat:@"AVAssetWriter Failed"]);
      return;
    }
    if (![_audioWriterInput appendSampleBuffer:sampleBuffer]) {
        _eventSink([NSString stringWithFormat:@"Unable to write to audio input"]);
    }
}

- (void)close {
  [_captureSession stopRunning];
  for (AVCaptureInput *input in [_captureSession inputs]) {
    [_captureSession removeInput:input];
  }
  for (AVCaptureOutput *output in [_captureSession outputs]) {
    [_captureSession removeOutput:output];
  }
}

- (void)dealloc {
  if (_latestPixelBuffer) {
    CFRelease(_latestPixelBuffer);
  }
}

- (CVPixelBufferRef)copyPixelBuffer {
  CVPixelBufferRef pixelBuffer = _latestPixelBuffer;
  while (!OSAtomicCompareAndSwapPtrBarrier(pixelBuffer, nil, (void **)&_latestPixelBuffer)) {
    pixelBuffer = _latestPixelBuffer;
  }
  return pixelBuffer;
}

- (FlutterError *_Nullable)onCancelWithArguments:(id _Nullable)arguments {
  _eventSink = nil;
  return nil;
}

- (FlutterError *_Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
  _eventSink = events;
  return nil;
}
- (void)startRecordingVideoAtPath:(NSString *)path result:(FlutterResult)result {

  if (!_isRecording) {
    if (![self setupWriterForPath:path]) {
    _eventSink([NSString stringWithFormat:@"Setup Writer Failed"]);
      return;
    }
      [_captureSession stopRunning];
    _isRecording = YES;
      [_captureSession startRunning];
  }
}

- (void)stopRecordingVideoWithResult:(FlutterResult)result{
  if (_isRecording)
  {
    _isRecording = NO;
      __block NSString *path = _videoWriter.outputURL.absoluteString;
    if (_videoWriter.status != 0) {
      [_videoWriter finishWritingWithCompletionHandler:^{
          result(@{@"outputURL":path});
      }];
    }
  }
}

- (BOOL)setupWriterForPath:(NSString *)path {
  NSError *error = nil;
    NSURL *outputURL;
  if (path != nil) {
    outputURL = [NSURL fileURLWithPath:path];
  }
    else
    {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsDirectoryPath = [paths objectAtIndex:0];
        time_t unixTime = (time_t)[[NSDate date] timeIntervalSince1970];
        NSString *timestamp = [NSString stringWithFormat:@"%ld", unixTime];
        NSString *filename = [NSString stringWithFormat:@"iPhoneVideo_%@.mp4", timestamp];
        outputURL =
        [NSURL fileURLWithPath:[documentsDirectoryPath stringByAppendingPathComponent:filename]];
    }
  _videoWriter =
      [[AVAssetWriter alloc] initWithURL:outputURL fileType:AVFileTypeQuickTimeMovie error:&error];
  NSParameterAssert(_videoWriter);

  NSDictionary *videoSettings = [NSDictionary
      dictionaryWithObjectsAndKeys:AVVideoCodecH264, AVVideoCodecKey,
                                   [NSNumber numberWithInt:_previewSize.height], AVVideoWidthKey,
                                   [NSNumber numberWithInt:_previewSize.width], AVVideoHeightKey,
                                   nil];
  _videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                         outputSettings:videoSettings];
  NSParameterAssert(_videoWriterInput);
  _videoWriterInput.expectsMediaDataInRealTime = YES;

  // Add the audio input
  AudioChannelLayout acl;
  bzero(&acl, sizeof(acl));
  acl.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
  NSDictionary *audioOutputSettings = nil;
  // Both type of audio inputs causes output video file to be corrupted.
  audioOutputSettings = [NSDictionary
      dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:kAudioFormatMPEG4AAC], AVFormatIDKey,
                                   [NSNumber numberWithFloat:44100.0], AVSampleRateKey,
                                   [NSNumber numberWithInt:1], AVNumberOfChannelsKey,
                                   [NSData dataWithBytes:&acl length:sizeof(acl)],
                                   AVChannelLayoutKey, nil];
  _audioWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                         outputSettings:audioOutputSettings];
  _audioWriterInput.expectsMediaDataInRealTime = YES;
  [_videoWriter addInput:_videoWriterInput];
    [_videoWriter addInput:_audioWriterInput];
  dispatch_queue_t queue = dispatch_queue_create("MyQueue", NULL);
  [_captureVideoOutput setSampleBufferDelegate:self queue:queue];
  [_audioOutput setSampleBufferDelegate:self queue:queue];

  return YES;
}
- (void)setUpCaptureSessionForAudio {
  NSError *error = nil;
  // Create a device input with the device and add it to the session.
  // Setup the audio input
  AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
  AVCaptureDeviceInput *audioInput =
      [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&error];
  // Setup the audio output
  _audioOutput = [[AVCaptureAudioDataOutput alloc] init];

  if ([_captureSession canAddInput:audioInput]) {
    [_captureSession addInput:audioInput];

    if ([_captureSession canAddOutput:_audioOutput]) {
      [_captureSession addOutput:_audioOutput];
      _isAudioSetup = YES;
    } else {
        _eventSink([NSString stringWithFormat:@"Error: Unable to add Audio input/output to session capture"]);
      _isAudioSetup = NO;
    }
  }
}
@end

@interface CameraPlugin ()
@property(readonly, nonatomic) NSObject<FlutterTextureRegistry> *registry;
@property(readonly, nonatomic) NSObject<FlutterBinaryMessenger> *messenger;
@property(readonly, nonatomic) NSMutableDictionary *cams;
@end

@implementation CameraPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"plugins.flutter.io/camera"
                                  binaryMessenger:[registrar messenger]];
  CameraPlugin *instance =
      [[CameraPlugin alloc] initWithRegistry:[registrar textures] messenger:[registrar messenger]];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithRegistry:(NSObject<FlutterTextureRegistry> *)registry
                       messenger:(NSObject<FlutterBinaryMessenger> *)messenger {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _registry = registry;
  _messenger = messenger;
  _cams = [NSMutableDictionary dictionaryWithCapacity:1];
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if ([@"init" isEqualToString:call.method]) {
    for (NSNumber *textureId in _cams) {
      [_registry unregisterTexture:[textureId longLongValue]];
      [[_cams objectForKey:textureId] close];
    }
    [_cams removeAllObjects];
    result(nil);
  } else if ([@"availableCameras" isEqualToString:call.method]) {
    AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]
                              mediaType:AVMediaTypeVideo
                               position:AVCaptureDevicePositionUnspecified];
    NSArray<AVCaptureDevice *> *devices = discoverySession.devices;
    NSMutableArray<NSDictionary<NSString *, NSObject *> *> *reply =
        [[NSMutableArray alloc] initWithCapacity:devices.count];
    for (AVCaptureDevice *device in devices) {
      NSString *lensFacing;
      switch ([device position]) {
        case AVCaptureDevicePositionBack:
          lensFacing = @"back";
          break;
        case AVCaptureDevicePositionFront:
          lensFacing = @"front";
          break;
        case AVCaptureDevicePositionUnspecified:
          lensFacing = @"external";
          break;
      }
      [reply addObject:@{
        @"name" : [device uniqueID],
        @"lensFacing" : lensFacing,
      }];
    }
    result(reply);
  } else if ([@"openCamera" isEqualToString:call.method]) {
    NSString *cameraName = call.arguments[@"cameraName"];
    NSString *resolutionPreset = call.arguments[@"resolutionPreset"];
    NSError *error;
    FLTCam *cam = [[FLTCam alloc] initWithCameraName:cameraName
                                    resolutionPreset:resolutionPreset
                                               error:&error];
    if (error) {
      result([error flutterError]);
    } else {
      int64_t textureId = [_registry registerTexture:cam];
      _cams[@(textureId)] = cam;
      cam.onFrameAvailable = ^{
        [_registry textureFrameAvailable:textureId];
      };
      FlutterEventChannel *eventChannel = [FlutterEventChannel
          eventChannelWithName:[NSString
                                   stringWithFormat:@"flutter.io/cameraPlugin/cameraEvents%lld",
                                                    textureId]
               binaryMessenger:_messenger];
      [eventChannel setStreamHandler:cam];
      cam.eventChannel = eventChannel;
      result(@{
        @"textureId" : @(textureId),
        @"previewWidth" : @(cam.previewSize.width),
        @"previewHeight" : @(cam.previewSize.height),
        @"captureWidth" : @(cam.captureSize.width),
        @"captureHeight" : @(cam.captureSize.height),
      });
      // starting the choosen cam
      [cam start];
    }
  } else {
    NSDictionary *argsMap = call.arguments;
    NSUInteger textureId = ((NSNumber *)argsMap[@"textureId"]).unsignedIntegerValue;
    FLTCam *cam = _cams[@(textureId)];

    if ([@"takePicture" isEqualToString:call.method]) {
      [cam captureToFile:call.arguments[@"path"] result:result];
    } else if ([@"closeCamera" isEqualToString:call.method]) {
      [_registry unregisterTexture:textureId];
      [cam close];
      [_cams removeObjectForKey:@(textureId)];
      result(nil);
    } else if ([@"startVideoRecording" isEqualToString:call.method]) {
      [cam startRecordingVideoAtPath:call.arguments[@"filePath"] result:result];

    } else if ([@"stopVideoRecording" isEqualToString:call.method]) {
        [cam stopRecordingVideoWithResult:result];
      result(nil);
    } else {
      result(FlutterMethodNotImplemented);
    }
  }
}

@end
