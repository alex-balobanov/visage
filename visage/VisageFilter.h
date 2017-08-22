//
//  VisageFilter.h
//  visage
//
//  Created by Alex Balobanov on 8/15/17.
//  Copyright © 2017 ITlekt Corporation. All rights reserved.
//

#import <Foundation/Foundation.h>

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */
	
#include <GPUImage/GPUImage.h>
	
#if defined(__cplusplus)
}
#endif /* defined(__cplusplus) */

typedef NS_ENUM(NSInteger, VisageFilterViewMode) {
	VisageFilterViewModeFeaturePoints,
	VisageFilterViewModeWireframe,
	VisageFilterViewModeMesh,
};

@interface VisageFilter : GPUImageFilter

@property(nonatomic) VisageFilterViewMode mode;

- (instancetype)init;
- (void)saveModel;

@end
