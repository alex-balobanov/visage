//
//  VisageFilter.m
//  visage
//
//  Created by Alex Balobanov on 8/15/17.
//  Copyright © 2017 ITlekt Corporation. All rights reserved.
//

#import "VisageFilter.h"
#import <VisageTracker.h>
#import <GLKit/GLKit.h>

#define MAXIMUM_NUMBER_OF_FACES 	20
#define TRACKER_CONFIG 				"Facial Features Tracker - High.cfg"
#define LENGTH(x) 					(sizeof(x) / sizeof(*x))
#define FEATURE_POINTS(x) 			{x, sizeof(x) / sizeof(*x)}

// vertex shader
static NSString *const vertexShaderString = SHADER_STRING
(
 attribute vec4 position;
 attribute vec4 inputTextureCoordinate;
 uniform mat4 model;
 uniform mat4 view;
 uniform mat4 projection;
 varying vec2 textureCoordinate;
 void main() {
	 gl_PointSize = 5.0;
	 gl_Position = projection * view * model * position;
	 textureCoordinate = inputTextureCoordinate.xy;
 }
);

// fragment shader
static NSString *const fragmentShaderString = SHADER_STRING \
(
 uniform sampler2D inputImageTexture;
 uniform highp vec4 color;
 varying highp vec2 textureCoordinate;
 void main() {
	 gl_FragColor = color * texture2D(inputImageTexture, vec2(1.0 - textureCoordinate.s, textureCoordinate.t));
 }
);

// neccessary prototype declaration for licensing visage sdk
namespace VisageSDK {
	void initializeLicenseManager(const char *licenseKeyFileFolder);
}

// visage feature points
struct FeaturePointId {
	int group;
	int index;
};

struct FeaturePoints {
	FeaturePointId *ids;
	int count;
};

// implementation
@interface VisageFilter() {
	// visage sdk
	VisageSDK::VisageTracker *_tracker;
	
	// wireframe indices buffer
	GLushort *_wireframeIndices;				// wireframe indices buffer
	GLint _wireframeIndicesCount;				// wireframe indices count
	GLint _wireframeIndicesMaxCount;			// max wireframe indices count
	
	// image data buffer
	GLubyte *_imageData;						// image data buffer
	GLint _imageDataLength;						// actual image data length
	GLint _imageWidth;							// actual image width
	GLint _imageHeight;							// actual image height
	GLint _imageDataMaxLength;					// max image data buffer length
	
	// for shaders
	GLuint _attributePosition;					// "position"
	GLuint _attributeNormal;					// "normal"
	GLuint _attributeInputTextureCoordinate;	// "inputTextureCoordinate"
	GLuint _uniformModelMatrix;					// "model"
	GLuint _uniformViewMatrix;					// "view"
	GLuint _uniformProjectionMatrix;			// "projection"
	GLuint _uniformInputImageTexture;			// "inputImageTexture"
	GLuint _uniformColor;						// "color"
}

@property(nonatomic) GLProgram *program;

@end

@implementation VisageFilter

- (instancetype)init {
	if ((self = [super init])) {
		// init visage sdk
		//VisageSDK::initializeLicenseManager("name-of-the-license-file.vlc");
		_tracker = new VisageSDK::VisageTracker(TRACKER_CONFIG);
		
		// create vertex and fragment shaders
		[self prepareShaders];
	}
	return self;
}

- (void)changeMode {
	runSynchronouslyOnVideoProcessingQueue(^{
		
	});
}


- (void)prepareShaders {
	// vertex and fragment shaders
	runSynchronouslyOnVideoProcessingQueue(^{
		[GPUImageContext useImageProcessingContext];
		self.program = [[GPUImageContext sharedImageProcessingContext] programForVertexShaderString:vertexShaderString fragmentShaderString:fragmentShaderString];
		[self.program addAttribute:@"position"];
		[self.program addAttribute:@"inputTextureCoordinate"];
		
		if (![self.program link]) {
			NSLog(@"Program link log: %@",  [self.program programLog]);
			NSLog(@"Fragment shader compile log: %@", [self.program fragmentShaderLog]);
			NSLog(@"Vertex shader compile log: %@", [self.program vertexShaderLog]);
			NSAssert(NO, @"Shader link failed");
		}
		
		// uniforms
		_uniformModelMatrix = [self.program uniformIndex:@"model"];
		_uniformViewMatrix = [self.program uniformIndex:@"view"];
		_uniformProjectionMatrix = [self.program uniformIndex:@"projection"];
		_uniformInputImageTexture = [self.program uniformIndex:@"inputImageTexture"];
		_uniformColor = [self.program uniformIndex:@"color"];
		
		// attributes
		_attributePosition = [self.program attributeIndex:@"position"];
		_attributeNormal = [self.program attributeIndex:@"normal"];
		_attributeInputTextureCoordinate = [self.program attributeIndex:@"inputTextureCoordinate"];
		
		// enable attributes
		[GPUImageContext setActiveShaderProgram:self.program];
		glEnableVertexAttribArray(_attributePosition);
		glEnableVertexAttribArray(_attributeNormal);
		glEnableVertexAttribArray(_attributeInputTextureCoordinate);
	});
}

- (void)dealloc {
	// visage sdk
	delete _tracker;
	
	// buffers
	if (_wireframeIndices) {
		free(_wireframeIndices);
	}
	if (_imageData) {
		free(_imageData);
	}
}

#pragma mark -
#pragma mark Visage SDK

- (void)featurePoints:(VisageSDK::FDP *)fdp ids:(FeaturePointId *)ids count:(NSInteger)count buffer:(GLKVector3 *)buffer {
	for (int i = 0; i < count; ++i) {
		const VisageSDK::FeaturePoint &fp = fdp->getFP(ids[i].group, ids[i].index);
		if (fp.defined) {
			buffer[i] = {fp.pos[0], fp.pos[1], fp.pos[2]};
		}
	}
}

- (void)genWireframeModelIndicesFrom:(const VisageSDK::FaceData &)faceData {
	// check wireframe indices buffer
	_wireframeIndicesCount = faceData.faceModelTriangleCount * 6;	// 1 triangle => 3 lines (6 indices)
	if (!_wireframeIndices || _wireframeIndicesMaxCount < _wireframeIndicesCount) {
		// alloc or realloc memory if needed
		if (_wireframeIndices) {
			free(_wireframeIndices);
		}
		_wireframeIndices = (typeof(_wireframeIndices))malloc(_wireframeIndicesCount * sizeof(*_wireframeIndices));
		_wireframeIndicesMaxCount = _wireframeIndicesCount;
	}
	
	// build wireframe model
	for (int i = 0; i < faceData.faceModelTriangleCount; ++i) {
		// 3 vertices for each triangle
		GLushort index0 = static_cast<GLushort>(faceData.faceModelTriangles[3 * i]);
		GLushort index1 = static_cast<GLushort>(faceData.faceModelTriangles[3 * i + 1]);
		GLushort index2 = static_cast<GLushort>(faceData.faceModelTriangles[3 * i + 2]);
		
		// swap indices if needed
		if (index0 > index1) {
			swap(index0, index1);
		}
		if (index0 > index2) {
			swap(index0, index2);
		}
		if (index1 > index2) {
			swap(index1, index2);
		}
		GLushort lineIndices[] = {
			index0, index1,
			index1, index2,
			index0, index2
		};
		
		// copy to the buffer for future use
		memcpy(&_wireframeIndices[6 * i], lineIndices, sizeof(lineIndices));
	}
}

- (int *)trackFacesIn:(GPUImageFramebuffer *)framebuffer outputFaceData:(VisageSDK::FaceData *)outputFaceData {
	// update image data buffer
	_imageWidth = framebuffer.size.width;
	_imageHeight = framebuffer.size.height;
	_imageDataLength = _imageWidth * _imageHeight * 4;
	if (!_imageData || _imageDataMaxLength < _imageDataLength) {
		// alloc or realloc memory if needed
		if (_imageData) {
			free(_imageData);
		}
		_imageData = (typeof(_imageData))malloc(_imageDataLength);
		_imageDataMaxLength = _imageDataLength;
	}
	
	// read current frame buffer into image data
	[GPUImageContext useImageProcessingContext];
	[framebuffer activateFramebuffer];
	glReadPixels(0, 0, _imageWidth, _imageHeight, GL_RGBA, GL_UNSIGNED_BYTE, _imageData);
	
	// track image data
	return _tracker->track(_imageWidth, _imageHeight, (const char *)_imageData, outputFaceData, VISAGE_FRAMEGRABBER_FMT_RGBA, VISAGE_FRAMEGRABBER_ORIGIN_TL, 0, -1, MAXIMUM_NUMBER_OF_FACES);
}

#pragma mark -
#pragma mark Filter

- (void)renderToTextureWithVertices:(const GLfloat *)vertices textureCoordinates:(const GLfloat *)textureCoordinates {
	// we need a normal color texture for this filter
	NSAssert(self.outputTextureOptions.internalFormat == GL_RGBA, @"The output texture format for this filter must be GL_RGBA.");
	NSAssert(self.outputTextureOptions.type == GL_UNSIGNED_BYTE, @"The type of the output texture of this filter must be GL_UNSIGNED_BYTE.");
	if (self.preventRendering) {
		[firstInputFramebuffer unlock];
		return;
	}
	
	// track faces in the input frame buffer
	static VisageSDK::FaceData faceData[MAXIMUM_NUMBER_OF_FACES];
	int *trackerStatus = [self trackFacesIn:firstInputFramebuffer outputFaceData:faceData];
	
	// create and activate output frame buffer
	[GPUImageContext setActiveShaderProgram:filterProgram];
	outputFramebuffer = [[GPUImageContext sharedFramebufferCache] fetchFramebufferForSize:[self sizeOfFBO] textureOptions:self.outputTextureOptions onlyTexture:NO];
	[outputFramebuffer activateFramebuffer];
	if (usingNextFrameForImageCapture) {
		[outputFramebuffer lock];
	}
	[self setUniformsForProgramAtIndex:0];
	
	// clear color and depth buffer
	glClearColor(backgroundColorRed, backgroundColorGreen, backgroundColorBlue, backgroundColorAlpha);
	//glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	glClear(GL_COLOR_BUFFER_BIT);
	
	// draw original frame (input framebuffer)
	glActiveTexture(GL_TEXTURE2);
	glBindTexture(GL_TEXTURE_2D, [firstInputFramebuffer texture]);
	glUniform1i(filterInputTextureUniform, 2);
	glVertexAttribPointer(filterPositionAttribute, 2, GL_FLOAT, 0, 0, vertices);
	glVertexAttribPointer(filterTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, textureCoordinates);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	
	// draw faces
	for (int i = 0; i < MAXIMUM_NUMBER_OF_FACES; ++i) {
		// use another shader program
		[GPUImageContext setActiveShaderProgram:self.program];
		
		// check status
		if (trackerStatus[i] == TRACK_STAT_OK) {
			VisageSDK::FaceData &currentFaceData = faceData[i];
			glBindTexture(GL_TEXTURE_2D, [firstInputFramebuffer texture]);
			glUniform1i(_uniformInputImageTexture, 2);
			
			// model matrix
			const float *r = currentFaceData.faceRotation;
			const float *t = currentFaceData.faceTranslation;
			//because x and z axes in OpenGL are opposite from the ones used by visage
			GLKMatrix4 modelMatrix = GLKMatrix4MakeTranslation(-t[0], t[1], -t[2]);
			modelMatrix = GLKMatrix4RotateY(modelMatrix, r[1]);
			modelMatrix = GLKMatrix4RotateX(modelMatrix, r[0]);
			modelMatrix = GLKMatrix4RotateZ(modelMatrix, r[2]);
			glUniformMatrix4fv(_uniformModelMatrix, 1, 0, modelMatrix.m);
			
			// view matrix
			GLKMatrix4 viewMatrix = GLKMatrix4MakeLookAt(0, 0, 0, 0, 0, -1, 0, 1, 0);
			glUniformMatrix4fv(_uniformViewMatrix, 1, 0, viewMatrix.m);
			
			// projection matrix
			GLfloat x_offset = 1;
			GLfloat y_offset = 1;
			if (_imageWidth > _imageHeight) {
				x_offset = ((GLfloat)_imageWidth) / ((GLfloat)_imageHeight);
			}
			else if (_imageWidth < _imageHeight) {
				y_offset = ((GLfloat)_imageHeight) / ((GLfloat)_imageWidth);
			}
			// FOV in radians is: fov*0.5 = arctan ((top-bottom)*0.5 / near)
			// In this case: FOV = 2 * arctan(frustum_y / frustum_near)
			GLfloat frustum_near = 0.001f;
			GLfloat frustum_far = 30; //hard to estimate face too far away
			GLfloat frustum_x = x_offset * frustum_near / currentFaceData.cameraFocus;
			GLfloat frustum_y = y_offset * frustum_near / currentFaceData.cameraFocus;
			//GLKMatrix4 projectionMatrix = GLKMatrix4MakeFrustum(-frustum_x,frustum_x,-frustum_y,frustum_y,frustum_near,frustum_far);
			GLKMatrix4 projectionMatrix = GLKMatrix4MakeFrustum(-frustum_x, frustum_x, frustum_y, -frustum_y,frustum_near,frustum_far); // show upside-down
			glUniformMatrix4fv(_uniformProjectionMatrix, 1, 0, projectionMatrix.m);
 
			// draw current wireframe model
			[self genWireframeModelIndicesFrom:currentFaceData];
			if (_wireframeIndicesCount) {
				glVertexAttribPointer(_attributePosition, 3, GL_FLOAT, 0, 0, currentFaceData.faceModelVertices);
				glUniform4f(_uniformColor, 0.0, 1.0, 0.0, 1.0);
				glDrawElements(GL_LINES, _wireframeIndicesCount, GL_UNSIGNED_SHORT, _wireframeIndices);
			}

			// draw feature points
			static FeaturePointId mouthInnerPointIds[] = { {2,	2}, {2,	6}, {2,	4}, {2,	8}, {2,	3}, {2,	9}, {2,	5}, {2,	7} };
			static FeaturePointId mouthOuterPointIds[] = { {8,	1}, {8,	10}, {8, 5}, {8, 3}, {8, 7}, {8, 2}, {8, 8}, {8, 4}, {8, 6}, {8, 9} };
			static FeaturePointId rightEyebrowPointIds[] = { {4, 6}, {14, 4}, {4, 4}, {14, 2}, {4, 2} };
			static FeaturePointId rightEyePointIds[] = { {3, 12}, {12, 10}, {3, 2}, {12, 6}, {3, 8}, {12, 8}, {3, 4}, {12, 12} };
			static FeaturePointId leftEyebrowPointIds[] = { {4, 1}, {14, 1}, {4, 3}, {14, 3}, {4, 5} };
			static FeaturePointId leftEyePointIds[] = { {3, 11}, {12, 9}, {3, 1}, {12, 5}, {3, 7}, {12, 7}, {3, 3}, {12, 11} };
			static FeaturePointId noseInnerPointIds[] = { {9, 1}, {9, 5}, {9, 15}, {9, 4}, {9, 2}, {9, 3} };
			static FeaturePointId noseOuterPointIds[] = { {9, 6}, {9, 14}, {9, 2}, {9, 3},  {9, 1}, {9, 13}, {9, 7} };
			
			static GLKVector3 buffer[LENGTH(mouthInnerPointIds) + LENGTH(mouthOuterPointIds) +
									 LENGTH(rightEyebrowPointIds) + LENGTH(rightEyePointIds) +
									 LENGTH(leftEyebrowPointIds) + LENGTH(leftEyePointIds) +
									 LENGTH(noseInnerPointIds) + LENGTH(noseOuterPointIds)] = {0};
			
			static FeaturePoints elements[] = {
				FEATURE_POINTS(mouthInnerPointIds), FEATURE_POINTS(mouthOuterPointIds),
				FEATURE_POINTS(rightEyebrowPointIds), FEATURE_POINTS(rightEyePointIds),
				FEATURE_POINTS(leftEyebrowPointIds), FEATURE_POINTS(leftEyePointIds),
				FEATURE_POINTS(noseInnerPointIds), FEATURE_POINTS(noseOuterPointIds),
			};
			
			glUniform4f(_uniformColor, 1.0, 0.0, 0.0, 1.0);
			glVertexAttribPointer(_attributeInputTextureCoordinate, 3, GL_FLOAT, 0, 0, buffer);
			glVertexAttribPointer(_attributePosition, 3, GL_FLOAT, 0, 0, buffer);
			
			VisageSDK::FDP *fdp = currentFaceData.featurePoints3DRelative;
			int offset = 0;
			for (int n = 0; n < sizeof(elements) / sizeof(*elements); ++n) {
				FeaturePoints &element = elements[n];
				[self featurePoints:fdp ids:element.ids count:element.count buffer:buffer + offset];
				glDrawArrays(GL_LINE_LOOP, offset, element.count);
				glDrawArrays(GL_POINTS, offset, element.count);
				offset += element.count;
			}
		}
	}
	
	[firstInputFramebuffer unlock];
	if (usingNextFrameForImageCapture) {
		dispatch_semaphore_signal(imageCaptureSemaphore);
	}
}

@end
