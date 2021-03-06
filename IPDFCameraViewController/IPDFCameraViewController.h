//
//  IPDFCameraViewController.h
//  InstaPDF
//
//  Created by Maximilian Mackh on 06/01/15.
//  Copyright (c) 2015 mackh ag. All rights reserved.
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, IPDFCameraViewType) {
    IPDFCameraViewTypeBlackAndWhite,
    IPDFCameraViewTypeNormal
};

@interface IPDFCameraViewController : UIView

- (void)setupCameraView;

- (void)start;
- (void)stop;

@property (nonatomic, assign, getter=isBorderDetectionEnabled) BOOL borderDetectionEnabled;
@property (nonatomic, assign, getter=isTorchEnabled) BOOL torchEnabled;

@property (nonatomic, assign) IPDFCameraViewType cameraViewType;

- (void)focusAtPoint:(CGPoint)point completionHandler:(void (^)())completionHandler;

- (void)captureImageWithCompletionHander:(void (^)(UIImage *image))completionHandler;

@end
