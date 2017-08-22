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
#define FEATURE_POINTS(x, b) 		{x, sizeof(x) / sizeof(*x), b}

// vertex shader
static NSString *const vertexShaderString = SHADER_STRING
(
 attribute vec4 position;
 attribute vec4 normal;
 uniform mat4 model;
 uniform mat4 view;
 uniform mat4 projection;
 varying vec4 outNormal;
 varying vec4 outFragPos;
 void main() {
	 outFragPos = model * position;
	 outNormal = normal;
	 gl_Position = projection * view * outFragPos;
	 gl_PointSize = 5.0;
 }
);

// fragment shader
static NSString *const fragmentShaderString = SHADER_STRING \
(
 uniform highp vec4 objectColor;
 uniform highp vec4 lightColor;
 uniform highp vec4 lightPosition;
 uniform highp vec4 viewPosition;
 varying highp vec4 outNormal;
 varying highp vec4 outFragPos;
 
 void main() {
	 // ambient
	 highp float ambientStrength = 0.1;
	 highp vec4 ambient = ambientStrength * lightColor;
	 
	 // diffuse
	 highp vec4 lightDir = normalize(lightPosition - outFragPos);
	 highp float diff = max(dot(outNormal, lightDir), 0.0);
	 highp vec4 diffuse = diff * lightColor;
	 
	 // specular
	 highp float specularStrength = 0.5;
	 highp vec4 viewDir = normalize(viewPosition - outFragPos);
	 highp vec4 reflectDir = reflect(-lightDir, outNormal);
	 highp float spec = pow(max(dot(viewDir, reflectDir), 0.0), 32.0);
	 highp vec4 specular = specularStrength * spec * lightColor;
	 gl_FragColor = (ambient + diffuse + specular) * objectColor;
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
	BOOL closed;
};

// implementation
@interface VisageFilter() {
	// visage sdk
	VisageSDK::VisageTracker *_tracker;
	int _trackerStatus[MAXIMUM_NUMBER_OF_FACES];
	VisageSDK::FaceData _faceData[MAXIMUM_NUMBER_OF_FACES];
	
	// wireframe indices buffer
	GLushort *_wireframeIndices;				// wireframe indices buffer
	GLint _wireframeIndicesCount;				// wireframe indices count
	GLint _wireframeIndicesMaxCount;			// max wireframe indices count
	
	// normals buffer
	GLKVector3 *_normals;						// normals buffer
	GLint _normalsCount;						// normals count
	GLint _normalssMaxCount;					// max normals count

	// image data buffer
	GLubyte *_imageData;						// image data buffer
	GLint _imageDataLength;						// actual image data length
	GLint _imageWidth;							// actual image width
	GLint _imageHeight;							// actual image height
	GLint _imageDataMaxLength;					// max image data buffer length
	
	// for shaders
	GLuint _attributePosition;					// "position"
	GLuint _attributeNormal;					// "normal"
	GLuint _uniformModelMatrix;					// "model"
	GLuint _uniformViewMatrix;					// "view"
	GLuint _uniformProjectionMatrix;			// "projection"
	GLuint _uniformObjectColor;					// "objectColor"
	GLuint _uniformLightColor;					// "lightColor"
	GLuint _uniformLightPosition;				// "lightPosition"
	GLuint _uniformViewPosition;				// "viewPosition"
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
		
		// default view mode
		_mode = VisageFilterViewModeMesh;
	}
	return self;
}

- (void)prepareShaders {
	// vertex and fragment shaders
	runSynchronouslyOnVideoProcessingQueue(^{
		[GPUImageContext useImageProcessingContext];
		self.program = [[GPUImageContext sharedImageProcessingContext] programForVertexShaderString:vertexShaderString fragmentShaderString:fragmentShaderString];
		[self.program addAttribute:@"position"];
		[self.program addAttribute:@"normal"];
		
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
		_uniformObjectColor = [self.program uniformIndex:@"objectColor"];
		_uniformLightColor = [self.program uniformIndex:@"lightColor"];
		_uniformLightPosition = [self.program uniformIndex:@"lightPosition"];
		_uniformViewPosition = [self.program uniformIndex:@"viewPosition"];
		
		// attributes
		_attributePosition = [self.program attributeIndex:@"position"];
		_attributeNormal = [self.program attributeIndex:@"normal"];
		
		// enable attributes
		[GPUImageContext setActiveShaderProgram:self.program];
		glEnableVertexAttribArray(_attributePosition);
		glEnableVertexAttribArray(_attributeNormal);
	});
}

- (void)dealloc {
	// visage sdk
	delete _tracker;
	
	// buffers
	if (_wireframeIndices) {
		free(_wireframeIndices);
	}
	if (_normals) {
		free(_normals);
	}
	if (_imageData) {
		free(_imageData);
	}
}

- (void)setMode:(VisageFilterViewMode)mode {
	runSynchronouslyOnVideoProcessingQueue(^{
		_mode = mode;
	});
}

- (void)saveModel {
	runSynchronouslyOnVideoProcessingQueue(^{
		for (int i = 0; i < MAXIMUM_NUMBER_OF_FACES; ++i) {
			[self exportModel:_faceData[i] withFileName:[NSString stringWithFormat:@"model%d", i]];
		}
	});
}

#pragma mark -
#pragma mark Export

- (void)exportModel:(const VisageSDK::FaceData &)faceData withFileName:(NSString *)fileName {
	// file names in app documents folder
	NSURL *documents = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
	NSString *path = documents.path;
	NSString *objFile = [path stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.obj", fileName]];
	NSString *mtlFile = [path stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.mtl", fileName]];
	NSString *pngFile = [path stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", fileName]];
	
	// export to OBJ
	NSMutableString *obj = [NSMutableString string];
	[obj appendString:@"mtllib model.mtl\n"];
	
	// vertices
	GLKVector3 *vertices = (GLKVector3 *)faceData.faceModelVertices;
	for (int t = 0; t < faceData.faceModelVertexCount; ++t) {
		GLKVector3 v = vertices[t];
		[obj appendFormat:@"v %f %f %f\n", v.x, v.y, v.z];
	}
	
	// texture coords
	for (int t = 0; t < faceData.faceModelVertexCount; ++t) {
		float u = faceData.faceModelTextureCoords[2 * t + 0];
		float v = faceData.faceModelTextureCoords[2 * t + 1];
		[obj appendFormat:@"vt %f %f\n", 1 - u, 1 - v];
	}
	
	// normals
	GLKVector3 normals[1000] = {0};
	for (int i = 0; i < faceData.faceModelTriangleCount; ++i) {
		// 3 vertices for each triangle
		int index0 = faceData.faceModelTriangles[3 * i + 2];
		int index1 = faceData.faceModelTriangles[3 * i + 1];
		int index2 = faceData.faceModelTriangles[3 * i + 0];
		GLKVector3 &A = vertices[index0];
		GLKVector3 &B = vertices[index1];
		GLKVector3 &C = vertices[index2];
		GLKVector3 N = GLKVector3CrossProduct( GLKVector3Subtract(B, A), GLKVector3Subtract(C, A));
		normals[index0] = GLKVector3Add(normals[index0], N);
		normals[index1] = GLKVector3Add(normals[index1], N);
		normals[index2] = GLKVector3Add(normals[index2], N);
	}
	for (int i = 0; i < faceData.faceModelVertexCount; ++i) {
		GLKVector3 n = GLKVector3Normalize(normals[i]);
		[obj appendFormat:@"vn %f %f %f\n", n.x, n.y, n.z];
	}
	
	// faces
	[obj appendString:@"usemtl material\n"];
	for (int t = 0; t < faceData.faceModelTriangleCount; ++t) {
		int i0 = faceData.faceModelTriangles[3 * t + 2] + 1;
		int i1 = faceData.faceModelTriangles[3 * t + 1] + 1;
		int i2 = faceData.faceModelTriangles[3 * t + 0] + 1;
		[obj appendFormat:@"f %d/%d/%d %d/%d/%d %d/%d/%d\n", i0, i0, i0, i1, i1, i1, i2, i2, i2];
	}
	[[obj dataUsingEncoding:NSUTF8StringEncoding] writeToFile:objFile atomically:YES];
	
	// export to MTL
	NSMutableString *mtl = [NSMutableString string];
	[mtl appendString:@"newmtl material\n"];
	[mtl appendString:@"Ka 1.000000 1.000000 1.000000\n"];
	[mtl appendString:@"Kd 1.000000 1.000000 1.000000\n"];
	[mtl appendString:@"Ks 0.000000 0.000000 0.000000\n"];
	[mtl appendString:@"Tr 1.000000\n"];
	[mtl appendString:@"illum 1\n"];
	[mtl appendString:@"Ns 0.000000\n"];
	[mtl appendString:@"map_Kd model.png\n"];
	[[mtl dataUsingEncoding:NSUTF8StringEncoding] writeToFile:mtlFile atomically:YES];
	
	// export PNG
	CGDataProviderRef dataProvider = CGDataProviderCreateWithData(NULL, _imageData, _imageDataLength, nil);
	CGColorSpaceRef defaultRGBColorSpace = CGColorSpaceCreateDeviceRGB();
	CGImageRef cgImageFromBytes = CGImageCreate(_imageWidth, _imageHeight, 8, 32, 4 * _imageWidth, defaultRGBColorSpace, kCGBitmapByteOrderDefault | kCGImageAlphaLast, dataProvider, NULL, NO, kCGRenderingIntentDefault);
	UIImage *image = [[UIImage alloc] initWithCGImage:cgImageFromBytes];
	[UIImagePNGRepresentation(image) writeToFile:pngFile atomically:YES];
	CGDataProviderRelease(dataProvider);
	CGColorSpaceRelease(defaultRGBColorSpace);
}

#pragma mark -
#pragma mark Tracking

- (void)featurePoints:(VisageSDK::FDP *)fdp ids:(FeaturePointId *)ids count:(NSInteger)count buffer:(GLKVector3 *)buffer {
	for (int i = 0; i < count; ++i) {
		const VisageSDK::FeaturePoint &fp = fdp->getFP(ids[i].group, ids[i].index);
		if (fp.defined) {
			buffer[i] = { fp.pos[0], fp.pos[1], fp.pos[2] };
		}
	}
}

- (void)trackFacesIn:(GPUImageFramebuffer *)framebuffer {
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
	
	// track image data and save the results for future use
	int *trackerStatus = _tracker->track(_imageWidth, _imageHeight, (const char *)_imageData, _faceData, VISAGE_FRAMEGRABBER_FMT_RGBA, VISAGE_FRAMEGRABBER_ORIGIN_TL, 0, -1, MAXIMUM_NUMBER_OF_FACES);
	memcpy(_trackerStatus, trackerStatus, sizeof(_trackerStatus));
}

#pragma mark -
#pragma mark Rendering

- (void)renderWireframeModel:(const VisageSDK::FaceData &)faceData {
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
	
	// draw current wireframe model
	if (_wireframeIndicesCount) {
		glVertexAttribPointer(_attributeNormal, 3, GL_FLOAT, 0, 0, faceData.faceModelVertices); // fake normals
		glVertexAttribPointer(_attributePosition, 3, GL_FLOAT, 0, 0, faceData.faceModelVertices);
		glUniform4f(_uniformObjectColor, 0.0, 0.0, 1.0, 1.0);
		glDrawElements(GL_LINES, _wireframeIndicesCount, GL_UNSIGNED_SHORT, _wireframeIndices);
	}
}

- (void)renderFeaturePoints:(const VisageSDK::FaceData &)faceData {
	// feature points
	
	static FeaturePointId physicalcontourPointIds[] = { {15, 1}, {15, 3}, {15, 5}, {15, 7}, {15, 9}, {15, 11}, {15, 13}, {15, 15}, {15, 17},
														{15, 16}, {15, 14}, {15, 12}, {15, 10}, {15, 8}, {15, 6}, {15, 4}, {15, 2} };
	static FeaturePointId mouthInnerPointIds[] = { {2,	2}, {2,	6}, {2,	4}, {2,	8}, {2,	3}, {2,	9}, {2,	5}, {2,	7} };
	static FeaturePointId mouthOuterPointIds[] = { {8,	1}, {8,	10}, {8, 5}, {8, 3}, {8, 7}, {8, 2}, {8, 8}, {8, 4}, {8, 6}, {8, 9} };
	static FeaturePointId rightEyebrowPointIds[] = { {4, 6}, {14, 4}, {4, 4}, {14, 2}, {4, 2} };
	static FeaturePointId rightEyePointIds[] = { {3, 12}, {12, 10}, {3, 2}, {12, 6}, {3, 8}, {12, 8}, {3, 4}, {12, 12} };
	static FeaturePointId leftEyebrowPointIds[] = { {4, 1}, {14, 1}, {4, 3}, {14, 3}, {4, 5} };
	static FeaturePointId leftEyePointIds[] = { {3, 11}, {12, 9}, {3, 1}, {12, 5}, {3, 7}, {12, 7}, {3, 3}, {12, 11} };
	static FeaturePointId noseInnerPointIds[] = { {9, 1}, {9, 5}, {9, 15}, {9, 4}, {9, 2}, {9, 3} };
	static FeaturePointId noseOuterPointIds[] = { {9, 6}, {9, 14}, {9, 2}, {9, 3},  {9, 1}, {9, 13}, {9, 7} };
	
	static GLKVector3 buffer[LENGTH(physicalcontourPointIds) +
							 LENGTH(mouthInnerPointIds) + LENGTH(mouthOuterPointIds) +
							 LENGTH(rightEyebrowPointIds) + LENGTH(rightEyePointIds) +
							 LENGTH(leftEyebrowPointIds) + LENGTH(leftEyePointIds) +
							 LENGTH(noseInnerPointIds) + LENGTH(noseOuterPointIds)] = {0};
	
	static FeaturePoints elements[] = {
		FEATURE_POINTS(physicalcontourPointIds, NO),
		FEATURE_POINTS(mouthInnerPointIds, YES), FEATURE_POINTS(mouthOuterPointIds, YES),
		FEATURE_POINTS(rightEyebrowPointIds, YES), FEATURE_POINTS(rightEyePointIds, YES),
		FEATURE_POINTS(leftEyebrowPointIds, YES), FEATURE_POINTS(leftEyePointIds, YES),
		FEATURE_POINTS(noseInnerPointIds, YES), FEATURE_POINTS(noseOuterPointIds, NO),
	};
	
	glVertexAttribPointer(_attributeNormal, 3, GL_FLOAT, 0, 0, buffer); // fake normals
	glVertexAttribPointer(_attributePosition, 3, GL_FLOAT, 0, 0, buffer);
	glUniform4f(_uniformObjectColor, 0.0, 1.0, 0.0, 1.0);
	VisageSDK::FDP *fdp = faceData.featurePoints3DRelative;
	int offset = 0;
	for (int n = 0; n < sizeof(elements) / sizeof(*elements); ++n) {
		FeaturePoints &element = elements[n];
		[self featurePoints:fdp ids:element.ids count:element.count buffer:buffer + offset];
		glDrawArrays(element.closed ? GL_LINE_LOOP : GL_LINE_STRIP, offset, element.count);
		glDrawArrays(GL_POINTS, offset, element.count);
		offset += element.count;
	}
}

- (void)renderMeshModel:(const VisageSDK::FaceData &)faceData modelMatrix:(GLKMatrix4)modelMatrix {
	// check normals buffer
	_normalsCount = faceData.faceModelVertexCount;
	if (!_normals || _normalssMaxCount < _normalsCount) {
		// alloc or realloc memory if needed
		if (_normals) {
			free(_wireframeIndices);
		}
		_normals = (typeof(_normals))malloc(_normalsCount * sizeof(*_normals));
		_normalssMaxCount = _normalsCount;
	}
	
	// calculate normals
	memset(_normals, 0, _normalsCount * sizeof(*_normals));
	GLKVector3 *vertices = (GLKVector3 *)faceData.faceModelVertices;
	for (int i = 0; i < faceData.faceModelTriangleCount; ++i) {
		// 3 vertices for each triangle
		int index0 = faceData.faceModelTriangles[3 * i + 2];
		int index1 = faceData.faceModelTriangles[3 * i + 1];
		int index2 = faceData.faceModelTriangles[3 * i + 0];
		GLKVector3 &A = vertices[index0];
		GLKVector3 &B = vertices[index1];
		GLKVector3 &C = vertices[index2];
		GLKVector3 N = GLKVector3CrossProduct( GLKVector3Subtract(B, A), GLKVector3Subtract(C, A));
		_normals[index0] = GLKVector3Add(_normals[index0], N);
		_normals[index1] = GLKVector3Add(_normals[index1], N);
		_normals[index2] = GLKVector3Add(_normals[index2], N);
	}
	for (int i = 0; i < faceData.faceModelVertexCount; ++i) {
		bool b;
		_normals[i] = GLKVector3Normalize(GLKMatrix4MultiplyVector3(GLKMatrix4InvertAndTranspose(modelMatrix, &b), _normals[i]));
	}
	glUniform4f(_uniformObjectColor, 1.0, 0.5, 0.3, 1.0);
	glVertexAttribPointer(_attributeNormal, 3, GL_FLOAT, 0, 0, _normals);
	glVertexAttribPointer(_attributePosition, 3, GL_FLOAT, 0, 0, faceData.faceModelVertices);
	glDrawElements(GL_TRIANGLES, faceData.faceModelTriangleCount * 3, GL_UNSIGNED_INT, faceData.faceModelTriangles);
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
	[self trackFacesIn:firstInputFramebuffer];
	
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
	
	// use another shader program
	[GPUImageContext setActiveShaderProgram:self.program];
	glEnable(GL_DEPTH_TEST);
	glEnable(GL_CULL_FACE);
	glFrontFace(GL_CCW);
	glCullFace(GL_BACK);
	
	// draw faces
	for (int i = 0; i < MAXIMUM_NUMBER_OF_FACES; ++i) {
		// check status
		if (_trackerStatus[i] == TRACK_STAT_OK) {
			VisageSDK::FaceData &currentFaceData = _faceData[i];
			
			// common parameters
			glUniform4f(_uniformObjectColor, 0.0, 0.0, 0.0, 1.0);
			glUniform4f(_uniformLightColor, 1.0, 1.0, 1.0, 1.0);
			glUniform4f(_uniformViewPosition, 0.0, 0.0, 0.0, 1.0);
			glUniform4f(_uniformLightPosition, 0.0, 0.15, 0.5, 1.0);
			
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

			// rendering depends on current view mode
			switch (_mode) {
				case VisageFilterViewModeFeaturePoints:
					[self renderFeaturePoints:currentFaceData];
					break;
					
				case VisageFilterViewModeWireframe:
					[self renderWireframeModel:currentFaceData];
					break;
					
				case VisageFilterViewModeMesh:
					[self renderMeshModel:currentFaceData modelMatrix:modelMatrix];
					break;
					
				default:
					NSAssert(NO, @"Unknown view mode.");
					break;
			}
		}
	}
	
	glDisable(GL_CULL_FACE);
	glDisable(GL_DEPTH_TEST);
	[firstInputFramebuffer unlock];
	if (usingNextFrameForImageCapture) {
		dispatch_semaphore_signal(imageCaptureSemaphore);
	}
}

@end
