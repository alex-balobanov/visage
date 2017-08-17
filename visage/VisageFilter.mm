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

#define MAXIMUM_NUMBER_OF_FACES 20

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
		// VisageSDK::initializeLicenseManager("name-of-the-license-file.vlc");
		_tracker = new VisageSDK::VisageTracker("Facial Features Tracker - High.cfg");
		
		// create vertex and fragment shaders
		[self prepareShaders];
	}
	return self;
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
		_attributeInputTextureCoordinate = [self.program attributeIndex:@"inputTextureCoordinate"];
		
		// enable attributes
		[GPUImageContext setActiveShaderProgram:self.program];
		glEnableVertexAttribArray(_attributePosition);
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
		GLushort index0 = static_cast<GLushort>(faceData.faceModelTriangles[3 * i + 0]);
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
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	
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
			
			// load vertices from face model
			glVertexAttribPointer(_attributePosition, 3, GL_FLOAT, 0, 0, currentFaceData.faceModelVertices);
			
			// draw current wireframe model
			[self genWireframeModelIndicesFrom:currentFaceData];
			if (_wireframeIndicesCount) {
				glUniform4f(_uniformColor, 1.0, 0.5, 0.5, 1.0);
				glDrawElements(GL_LINES, _wireframeIndicesCount, GL_UNSIGNED_SHORT, _wireframeIndices);
			}
		}
	}
	
	[firstInputFramebuffer unlock];
	if (usingNextFrameForImageCapture) {
		dispatch_semaphore_signal(imageCaptureSemaphore);
	}
}

@end
