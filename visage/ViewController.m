//
//  ViewController.m
//  visage
//
//  Created by Alex Balobanov on 8/15/17.
//  Copyright © 2017 ITlekt Corporation. All rights reserved.
//

#import "ViewController.h"
#import "VisageFilter.h"
#import <GPUImage.h>

@interface ViewController ()
@property(nonatomic) IBOutlet GPUImageView *view;
@property(nonatomic) GPUImageVideoCamera *camera;
@property(nonatomic) VisageFilter *filter;
@end

@implementation ViewController

@dynamic view;

- (BOOL)prefersStatusBarHidden {
	return YES;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	
	// camera
	self.camera = [[GPUImageVideoCamera alloc] initWithSessionPreset:AVCaptureSessionPresetHigh cameraPosition:AVCaptureDevicePositionFront];
	self.camera.outputImageOrientation = UIInterfaceOrientationPortrait;
	self.camera.horizontallyMirrorFrontFacingCamera = YES;
	
	// filter
	self.filter = [[VisageFilter alloc] init];
	
	// processing chain
	[self.camera addTarget:self.filter];
	[self.filter addTarget:self.view];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	// start camera capturing
	[self.camera startCameraCapture];
}

- (void)viewDidDisappear:(BOOL)animated {
	[super viewDidDisappear:animated];
	// stop camera capturing
	[self.camera stopCameraCapture];
}

- (void)didReceiveMemoryWarning {
	[super didReceiveMemoryWarning];
	// Dispose of any resources that can be recreated.
}

#pragma mark -
#pragma mark Actions

- (IBAction)changeViewButtonPressed:(id)sender {
	static VisageFilterViewMode modes[] = { VisageFilterViewModeFeaturePoints, VisageFilterViewModeWireframe, VisageFilterViewModeMesh };
	static NSUInteger index = 0;
	self.filter.mode = modes[++index % (sizeof(modes)/sizeof(*modes))];
}

- (IBAction)saveModelButtonPressed:(id)sender {
	[self.filter saveModel];
}

@end
