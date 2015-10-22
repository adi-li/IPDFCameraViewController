//
//  IPDFCameraViewController.m
//  InstaPDF
//
//  Created by Maximilian Mackh on 06/01/15.
//  Copyright (c) 2015 mackh ag. All rights reserved.
//

#import "IPDFCameraViewController.h"

@import AVFoundation;
@import CoreMedia;
@import CoreVideo;
@import QuartzCore;
@import CoreImage;
@import ImageIO;
@import MobileCoreServices;
@import GLKit;

@interface IPDFCameraViewController () <AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureDevice *captureDevice;
@property (nonatomic, strong) EAGLContext *context;

@property (nonatomic, strong) AVCaptureStillImageOutput *stillImageOutput;

@property (nonatomic, assign) BOOL forceStop;

@property (nonatomic, assign, getter=isRectangleDetectionConfidenceHighEnough)
BOOL rectangleDetectionConfidenceHighEnough;

@end

@implementation IPDFCameraViewController {
    CIContext *_coreImageContext;
    GLuint _renderBuffer;
    GLKView *_glkView;

    BOOL _isStopped;

    CGFloat _imageDedectionConfidence;
    NSTimer *_borderDetectTimeKeeper;
    BOOL _borderDetectFrame;
    CIRectangleFeature *_borderDetectLastRectangleFeature;

    BOOL _isCapturing;
    dispatch_queue_t _captureQueue;
}

#pragma mark - Life cycle

- (void)awakeFromNib
{
    [super awakeFromNib];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_backgroundMode) name:UIApplicationWillResignActiveNotification object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_foregroundMode) name:UIApplicationDidBecomeActiveNotification object:nil];

    _captureQueue = dispatch_queue_create("com.instapdf.AVCameraCaptureQueue", DISPATCH_QUEUE_SERIAL);
}

- (void)_backgroundMode
{
    self.forceStop = YES;
}

- (void)_foregroundMode
{
    self.forceStop = NO;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


#pragma mark - Setup views

- (void)createGLKView
{
    if (self.context)
        return;

    self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    GLKView *view = [[GLKView alloc] initWithFrame:self.bounds];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.translatesAutoresizingMaskIntoConstraints = YES;
    view.context = self.context;
    view.contentScaleFactor = 1.0f;
    view.drawableDepthFormat = GLKViewDrawableDepthFormat24;
    [self insertSubview:view atIndex:0];
    _glkView = view;
    _coreImageContext =
    [CIContext contextWithEAGLContext:self.context
                              options:@{kCIContextWorkingColorSpace: [NSNull null],
                                        kCIContextUseSoftwareRenderer: @NO}];
}

- (void)setupCameraView
{
    [self createGLKView];

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device)
        return;

    _imageDedectionConfidence = 0.0;

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    self.captureSession = session;
    [session beginConfiguration];
    self.captureDevice = device;

    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    session.sessionPreset = AVCaptureSessionPresetPhoto;
    [session addInput:input];

    AVCaptureVideoDataOutput *dataOutput = [[AVCaptureVideoDataOutput alloc] init];
    dataOutput.alwaysDiscardsLateVideoFrames = YES;
    dataOutput.videoSettings = @{(NSString *)kCVPixelBufferPixelFormatTypeKey:
                                     @(kCVPixelFormatType_32BGRA)};
    [dataOutput setSampleBufferDelegate:self queue:_captureQueue];
    [session addOutput:dataOutput];

    self.stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
    [session addOutput:self.stillImageOutput];

    AVCaptureConnection *connection = dataOutput.connections.firstObject;
    connection.videoOrientation = AVCaptureVideoOrientationPortrait;

    if (device.isFlashAvailable) {
        [device lockForConfiguration:nil];

        if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
            device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
        } else {
            device.flashMode = AVCaptureFlashModeOff;
        }

        [device unlockForConfiguration];
    }

    [session commitConfiguration];
}


#pragma mark - Properties asscessors

- (void)setCameraViewType:(IPDFCameraViewType)cameraViewType
{
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *viewWithBlurredBackground = [[UIVisualEffectView alloc] initWithEffect:effect];
    viewWithBlurredBackground.frame = self.bounds;
    [self insertSubview:viewWithBlurredBackground aboveSubview:_glkView];

    _cameraViewType = cameraViewType;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   ^{
                       [viewWithBlurredBackground removeFromSuperview];
                   });
}

- (void)setTorchEnabled:(BOOL)torchEnabled
{
    _torchEnabled = torchEnabled;

    AVCaptureDevice *device = self.captureDevice;
    if (device.hasTorch && device.hasFlash) {
        [device lockForConfiguration:nil];
        if (torchEnabled) {
            device.torchMode = AVCaptureTorchModeOn;
        } else {
            device.torchMode = AVCaptureTorchModeOff;
        }
        [device unlockForConfiguration];
    }
}


#pragma mark - Start / Stop capturing

- (void)start
{
    _isStopped = NO;

    [self.captureSession startRunning];

    _borderDetectTimeKeeper =
    [NSTimer scheduledTimerWithTimeInterval:0.032
                                     target:self selector:@selector(enableBorderDetectFrame)
                                   userInfo:nil repeats:YES];

    [self hideGLKView:NO completion:nil];
}

- (void)stop
{
    _isStopped = YES;

    [self.captureSession stopRunning];

    [_borderDetectTimeKeeper invalidate];

    [self hideGLKView:YES completion:nil];
}

- (void)enableBorderDetectFrame
{
    _borderDetectFrame = YES;
}

- (void)hideGLKView:(BOOL)hidden completion:(void (^)())completion
{
    [UIView animateWithDuration:0.1
                     animations:^{
                         _glkView.alpha = (hidden) ? 0.0 : 1.0;
                     }
                     completion:^(BOOL finished) {
                         if (completion) {
                             completion();
                         }
                     }];
}


#pragma mark - Manual focus

- (void)focusAtPoint:(CGPoint)point completionHandler:(void (^)())completionHandler
{
    AVCaptureDevice *device = self.captureDevice;
    CGPoint pointOfInterest = CGPointZero;
    CGSize frameSize = self.bounds.size;
    pointOfInterest = CGPointMake(point.y / frameSize.height, 1.f - (point.x / frameSize.width));

    if (device.focusPointOfInterestSupported && [device isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
        NSError *error;
        if ([device lockForConfiguration:&error]) {
            if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
                device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
                device.focusPointOfInterest = pointOfInterest;
            }

            if (device.exposurePointOfInterestSupported && [device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
                device.exposurePointOfInterest = pointOfInterest;
                device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
            }

            [device unlockForConfiguration];
        }
    }

    if (completionHandler) {
        completionHandler();
    }
}


#pragma mark - Capture image

- (void)captureImageWithCompletionHander:(void (^)(UIImage *image))completionHandler
{
    dispatch_suspend(_captureQueue);

    AVCaptureConnection *videoConnection = nil;
    for (AVCaptureConnection *connection in self.stillImageOutput.connections) {
        for (AVCaptureInputPort *port in connection.inputPorts) {
            if ([port.mediaType isEqual:AVMediaTypeVideo]) {
                videoConnection = connection;
                break;
            }
        }
        if (videoConnection) {
            break;
        }
    }

    void (^mainThreadCompletionHandler)(UIImage *) = ^(UIImage *image){
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            if (completionHandler) {
                completionHandler(image);
            }
            dispatch_resume(_captureQueue);
        }];
    };

    __weak typeof(self) weakSelf = self;

    [self.stillImageOutput
     captureStillImageAsynchronouslyFromConnection:videoConnection
     completionHandler:^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
         if (error) {
             return mainThreadCompletionHandler(nil);
         }

         @autoreleasepool
         {
             // Get image data
             NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageSampleBuffer];
             CIImage *enhancedImage = [[CIImage alloc] initWithData:imageData
                                                            options:@{kCIImageColorSpace : [NSNull null]}];
             imageData = nil;

             // Add Color / B&W filter
             if (weakSelf.cameraViewType == IPDFCameraViewTypeBlackAndWhite) {
                 enhancedImage = [self filteredImageUsingEnhanceFilterOnImage:enhancedImage];
             } else {
                 enhancedImage = [self filteredImageUsingContrastFilterOnImage:enhancedImage];
             }

             // Detect and crop rectangle, then correct perspective
             if (weakSelf.borderDetectionEnabled && weakSelf.rectangleDetectionConfidenceHighEnough) {
                 CIRectangleFeature *rectangleFeature =
                 [weakSelf biggestRectangleInRectangles:
                  [[weakSelf highAccuracyRectangleDetector] featuresInImage:enhancedImage]];

                 if (rectangleFeature) {
                     enhancedImage = [weakSelf correctPerspectiveForImage:enhancedImage withFeatures:rectangleFeature];
                 }
             }

             // Rotate image to left by 90 degrees.
             CIFilter *transform = [CIFilter filterWithName:@"CIAffineTransform"];
             [transform setValue:enhancedImage forKey:kCIInputImageKey];
             NSValue *rotation = [NSValue valueWithCGAffineTransform:CGAffineTransformMakeRotation(-90 * (M_PI / 180))];
             [transform setValue:rotation forKey:@"inputTransform"];
             enhancedImage = transform.outputImage;

             if (!enhancedImage || CGRectIsEmpty(enhancedImage.extent)) {
                 return mainThreadCompletionHandler(nil);
             }

             static CIContext *ctx = nil;
             if (!ctx) {
                 ctx = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace : [NSNull null]}];
             }

             CGSize bounds = enhancedImage.extent.size;
             bounds = CGSizeMake(floorf(bounds.width / 4) * 4, floorf(bounds.height / 4) * 4);
             CGRect extent = CGRectMake(enhancedImage.extent.origin.x, enhancedImage.extent.origin.y, bounds.width, bounds.height);

             static int bytesPerPixel = 8;
             uint rowBytes = bytesPerPixel * bounds.width;
             uint totalBytes = rowBytes * bounds.height;
             uint8_t *byteBuffer = malloc(totalBytes);

             CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

             [ctx render:enhancedImage toBitmap:byteBuffer rowBytes:rowBytes bounds:extent format:kCIFormatRGBA8 colorSpace:colorSpace];

             CGContextRef bitmapContext = CGBitmapContextCreate(byteBuffer, bounds.width, bounds.height, bytesPerPixel, rowBytes, colorSpace, kCGImageAlphaNoneSkipLast);
             CGImageRef imgRef = CGBitmapContextCreateImage(bitmapContext);
             CGColorSpaceRelease(colorSpace);
             CGContextRelease(bitmapContext);
             free(byteBuffer);

             if (imgRef == NULL) {
                 CFRelease(imgRef);
                 return mainThreadCompletionHandler(nil);
             }

             mainThreadCompletionHandler([UIImage imageWithCGImage:imgRef]);
             CFRelease(imgRef);

             _imageDedectionConfidence = 0.0f;
         }
     }];
}


#pragma mark - Image processing

- (CIImage *)drawHighlightOverlayForPoints:(CIImage *)image
                                   topLeft:(CGPoint)topLeft
                                  topRight:(CGPoint)topRight
                                bottomLeft:(CGPoint)bottomLeft
                               bottomRight:(CGPoint)bottomRight
{
    CIImage *overlay = [CIImage imageWithColor:[CIColor colorWithRed:1 green:0 blue:0 alpha:0.6]];
    overlay = [overlay imageByCroppingToRect:image.extent];
    overlay = [overlay
               imageByApplyingFilter:@"CIPerspectiveTransformWithExtent"
               withInputParameters:@{@"inputExtent": [CIVector vectorWithCGRect:image.extent],
                                     @"inputTopLeft": [CIVector vectorWithCGPoint:topLeft],
                                     @"inputTopRight": [CIVector vectorWithCGPoint:topRight],
                                     @"inputBottomLeft": [CIVector vectorWithCGPoint:bottomLeft],
                                     @"inputBottomRight": [CIVector vectorWithCGPoint:bottomRight]}];

    return [overlay imageByCompositingOverImage:image];
}

- (CIImage *)filteredImageUsingEnhanceFilterOnImage:(CIImage *)image
{
    return [CIFilter filterWithName:@"CIColorControls"
                withInputParameters:@{kCIInputImageKey: image,
                                      kCIInputBrightnessKey: @0,
                                      kCIInputContrastKey: @1.14,
                                      kCIInputSaturationKey: @0}].outputImage;
}

- (CIImage *)filteredImageUsingContrastFilterOnImage:(CIImage *)image
{
    return [CIFilter filterWithName:@"CIColorControls"
                withInputParameters:@{kCIInputImageKey: image,
                                      kCIInputContrastKey: @1.1}].outputImage;
}

- (CIImage *)correctPerspectiveForImage:(CIImage *)image
                           withFeatures:(CIRectangleFeature *)rectangleFeature
{
    return [image
            imageByApplyingFilter:@"CIPerspectiveCorrection"
            withInputParameters:@{@"inputTopLeft": [CIVector vectorWithCGPoint:
                                                    rectangleFeature.topLeft],
                                  @"inputTopRight": [CIVector vectorWithCGPoint:
                                                     rectangleFeature.topRight],
                                  @"inputBottomLeft": [CIVector vectorWithCGPoint:
                                                       rectangleFeature.bottomLeft],
                                  @"inputBottomRight": [CIVector vectorWithCGPoint:
                                                        rectangleFeature.bottomRight],
                                  }];
}

- (CIDetector *)rectangleDetetor
{
    static CIDetector *detector = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        detector = [CIDetector detectorOfType:CIDetectorTypeRectangle context:nil
                                      options:@{CIDetectorAccuracy: CIDetectorAccuracyLow,
                                                CIDetectorTracking: @YES}];
    });
    return detector;
}

- (CIDetector *)highAccuracyRectangleDetector
{
    static CIDetector *detector = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        detector = [CIDetector detectorOfType:CIDetectorTypeRectangle context:nil
                                      options:@{CIDetectorAccuracy : CIDetectorAccuracyHigh}];
    });
    return detector;
}

- (CIRectangleFeature *)biggestRectangleInRectangles:(NSArray *)rectangles
{
    if (!rectangles.count) {
        return nil;
    }

    CGFloat halfPerimiterValue = 0;

    CIRectangleFeature *biggestRectangle = rectangles.firstObject;

    for (CIRectangleFeature *rect in rectangles) {
        CGPoint p1 = rect.topLeft;
        CGPoint p2 = rect.topRight;
        CGFloat width = hypot(p1.x - p2.x, p1.y - p2.y);

        CGPoint p3 = rect.topLeft;
        CGPoint p4 = rect.bottomLeft;
        CGFloat height = hypot(p3.x - p4.x, p3.y - p4.y);

        CGFloat currentHalfPerimiterValue = height + width;

        if (halfPerimiterValue < currentHalfPerimiterValue) {
            halfPerimiterValue = currentHalfPerimiterValue;
            biggestRectangle = rect;
        }
    }

    return biggestRectangle;
}


- (BOOL)isRectangleDetectionConfidenceHighEnough
{
    return (_imageDedectionConfidence > 1.0);
}


#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    if (self.forceStop)
        return;
    if (_isStopped || _isCapturing || !CMSampleBufferIsValid(sampleBuffer))
        return;

    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sampleBuffer);

    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];

    if (self.cameraViewType != IPDFCameraViewTypeNormal) {
        image = [self filteredImageUsingEnhanceFilterOnImage:image];
    } else {
        image = [self filteredImageUsingContrastFilterOnImage:image];
    }

    if (self.borderDetectionEnabled) {
        if (_borderDetectFrame) {
            _borderDetectLastRectangleFeature = [self biggestRectangleInRectangles:[[self highAccuracyRectangleDetector] featuresInImage:image]];
            _borderDetectFrame = NO;
        }

        if (_borderDetectLastRectangleFeature) {
            _imageDedectionConfidence += .5;

            image = [self drawHighlightOverlayForPoints:image topLeft:_borderDetectLastRectangleFeature.topLeft topRight:_borderDetectLastRectangleFeature.topRight bottomLeft:_borderDetectLastRectangleFeature.bottomLeft bottomRight:_borderDetectLastRectangleFeature.bottomRight];
        } else {
            _imageDedectionConfidence = 0.0f;
        }
    }

    if (self.context && _coreImageContext) {
        if (_context != [EAGLContext currentContext]) {
            [EAGLContext setCurrentContext:_context];
        }
        [_glkView bindDrawable];
        [_coreImageContext drawImage:image inRect:self.bounds fromRect:image.extent];
        [_glkView display];
        
        image = nil;
    }
}

@end
