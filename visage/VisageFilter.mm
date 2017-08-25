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

// neccessary prototype declaration for licensing visage sdk
namespace VisageSDK {
	void initializeLicenseManager(const char *licenseKeyFileFolder);
}

// visage feature point identifier
struct FeaturePointId {
	int group;
	int index;
};

// visage feature points
struct FeaturePoints {
	FeaturePointId *ids;
	int count;
};

// Vertex attributes
struct Vertex {
	GLKVector4 position;
	GLKVector4 normal;
};

// vertex shader
static NSString *const vertexShaderString = SHADER_STRING
(
 attribute vec4 position;
 attribute vec4 normal;
 uniform mat4 model;
 uniform mat4 view;
 uniform mat4 projection;
 varying vec4 outPosition;
 varying vec4 outNormal;
 void main() {
	 outPosition = model * position;
	 outNormal = model * normal;
	 gl_Position = projection * view * outPosition;
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
 varying highp vec4 outPosition;
 varying highp vec4 outNormal;
 void main() {
	 // ambient
	 highp float ambientStrength = 0.1;
	 highp vec4 ambient = ambientStrength * lightColor;
	 
	 // diffuse
	 highp vec4 lightDir = normalize(lightPosition - outPosition);
	 highp float diff = max(dot(outNormal, lightDir), 0.0);
	 highp vec4 diffuse = diff * lightColor;
	 
	 // specular
	 highp float specularStrength = 0.5;
	 highp vec4 viewDir = normalize(viewPosition - outPosition);
	 highp vec4 reflectDir = reflect(-lightDir, outNormal);
	 highp float spec = pow(max(dot(viewDir, reflectDir), 0.0), 32.0);
	 highp vec4 specular = specularStrength * spec * lightColor;
	 gl_FragColor = (ambient + diffuse + specular) * objectColor;
 }
);

// feature points
static FeaturePointId physicalcontourPointIds[] = { {15, 1}, {15, 3}, {15, 5}, {15, 7}, {15, 9}, {15, 11}, {15, 13}, {15, 15}, {15, 17}, {15, 16}, {15, 14}, {15, 12}, {15, 10}, {15, 8}, {15, 6}, {15, 4}, {15, 2} };
static FeaturePointId mouthInnerPointIds[] = { {2,	2}, {2,	6}, {2,	4}, {2,	8}, {2,	3}, {2,	9}, {2,	5}, {2,	7}, {2, 2} };
static FeaturePointId mouthOuterPointIds[] = { {8,	1}, {8,	10}, {8, 5}, {8, 3}, {8, 7}, {8, 2}, {8, 8}, {8, 4}, {8, 6}, {8, 9}, {8, 1} };
static FeaturePointId rightEyebrowPointIds[] = { {4, 6}, {14, 4}, {4, 4}, {14, 2}, {4, 2} };
static FeaturePointId rightEyePointIds[] = { {3, 12}, {12, 10}, {3, 2}, {12, 6}, {3, 8}, {12, 8}, {3, 4}, {12, 12}, {3, 12} };
static FeaturePointId leftEyebrowPointIds[] = { {4, 1}, {14, 1}, {4, 3}, {14, 3}, {4, 5} };
static FeaturePointId leftEyePointIds[] = { {3, 11}, {12, 9}, {3, 1}, {12, 5}, {3, 7}, {12, 7}, {3, 3}, {12, 11}, {3, 11} };
static FeaturePointId noseInnerPointIds[] = { {9, 1}, {9, 5}, {9, 15}, {9, 4}, {9, 2}, {9, 3} };
static FeaturePointId noseOuterPointIds[] = { {9, 6}, {9, 14}, {9, 2}, {9, 3},  {9, 1}, {9, 13}, {9, 7} };

#define MAXIMUM_NUMBER_OF_FEATURE_POINTS  (LENGTH(physicalcontourPointIds) + \
											LENGTH(mouthInnerPointIds) + \
											LENGTH(mouthOuterPointIds) + \
											LENGTH(rightEyebrowPointIds) + \
											LENGTH(rightEyePointIds) + \
											LENGTH(leftEyebrowPointIds) + \
											LENGTH(leftEyePointIds) + \
											LENGTH(noseInnerPointIds) + \
											LENGTH(noseOuterPointIds))

static FeaturePoints featurePointsElements[] = {
	FEATURE_POINTS(physicalcontourPointIds),
	FEATURE_POINTS(mouthInnerPointIds),
	FEATURE_POINTS(mouthOuterPointIds),
	FEATURE_POINTS(rightEyebrowPointIds),
	FEATURE_POINTS(rightEyePointIds),
	FEATURE_POINTS(leftEyebrowPointIds),
	FEATURE_POINTS(leftEyePointIds),
	FEATURE_POINTS(noseInnerPointIds),
	FEATURE_POINTS(noseOuterPointIds),
};

// implementation
@interface VisageFilter() {
	// visage sdk
	VisageSDK::VisageTracker *_tracker;
	int _trackerStatus[MAXIMUM_NUMBER_OF_FACES];
	VisageSDK::FaceData _faceData[MAXIMUM_NUMBER_OF_FACES];
	GLKVector4 _featurePoints[ MAXIMUM_NUMBER_OF_FEATURE_POINTS * MAXIMUM_NUMBER_OF_FACES ];

	// vertext buffer
	Vertex *_vertices;							// [position, normal, ...]
	GLint _vertexCount;							// vertices count
	
	// wireframe indices buffer
	GLushort *_wireframeIndices;				// wireframe indices buffer
	GLint _wireframeIndicesCount;				// wireframe indices count
	
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
	if (_vertices) {
		free(_vertices);
	}
	if (_wireframeIndices) {
		free(_wireframeIndices);
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
		// file names in app documents folder
		NSURL *documents = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
		NSString *path = documents.path;

		GLint verticesOffset = 0;
		BOOL exportOtherFiles = NO;
		for (int i = 0; i < MAXIMUM_NUMBER_OF_FACES; ++i) {
			if (_trackerStatus[i] == TRACK_STAT_OK) {
				exportOtherFiles = YES;
				VisageSDK::FaceData &faceData = _faceData[i];
				Vertex *vertices = _vertices + verticesOffset;
				
				NSString *objFile = [path stringByAppendingPathComponent:[NSString stringWithFormat:@"model%d.obj", i]];
				NSLog(@"Export {%@}", objFile);
				[self exportObj:objFile vertices:vertices textureCoords:faceData.faceModelTextureCoords vertexCount:faceData.faceModelVertexCount triangles:faceData.faceModelTriangles triangleCount:faceData.faceModelTriangleCount];

				// move to the next face data
				verticesOffset += faceData.faceModelVertexCount;
			}
		}
		
		if (exportOtherFiles) {
			NSString *pngFile = [path stringByAppendingPathComponent:@"model.png"];
			NSLog(@"Export {%@}", pngFile);
			[self exportPng:pngFile];
			
			NSString *mtlFile = [path stringByAppendingPathComponent:@"model.mtl"];
			NSLog(@"Export {%@}", mtlFile);
			[self exportMtl:mtlFile];
		}
		
	});
}

#pragma mark -
#pragma mark Export

- (void)exportMtl:(NSString *)mtlFile {
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
}

- (void)exportPng:(NSString *)pngFile {
	CGDataProviderRef dataProvider = CGDataProviderCreateWithData(NULL, _imageData, _imageDataLength, nil);
	CGColorSpaceRef defaultRGBColorSpace = CGColorSpaceCreateDeviceRGB();
	CGImageRef cgImageFromBytes = CGImageCreate(_imageWidth, _imageHeight, 8, 32, 4 * _imageWidth, defaultRGBColorSpace, kCGBitmapByteOrderDefault | kCGImageAlphaLast, dataProvider, NULL, NO, kCGRenderingIntentDefault);
	UIImage *image = [[UIImage alloc] initWithCGImage:cgImageFromBytes];
	[UIImagePNGRepresentation(image) writeToFile:pngFile atomically:YES];
	CGDataProviderRelease(dataProvider);
	CGColorSpaceRelease(defaultRGBColorSpace);
}

- (void)exportObj:(NSString *)objFile vertices:(Vertex *)vertices textureCoords:(float *)textureCoords vertexCount:(int)vertexCount triangles:(int *)triangles triangleCount:(int)triangleCount {
	
	
	// export to OBJ
	NSMutableString *obj = [NSMutableString string];
	[obj appendString:@"mtllib model.mtl\n"];
	
	// vertices
	for (int i = 0; i < vertexCount; ++i) {
		GLKVector4 &v = vertices[i].position;
		[obj appendFormat:@"v %f %f %f\n", v.x, v.y, v.z];
	}
	
	// texture coords
	for (int i = 0; i < vertexCount; ++i) {
		float u = textureCoords[2 * i + 0];
		float v = textureCoords[2 * i + 1];
		[obj appendFormat:@"vt %f %f\n", 1.0f - u, 1.0f - v];
	}
	
	// normals
	for (int i = 0; i < vertexCount; ++i) {
		GLKVector4 &n = vertices[i].normal;
		[obj appendFormat:@"vn %f %f %f\n", n.x, n.y, n.z];
	}
	
	// faces
	[obj appendString:@"usemtl material\n"];
	for (int i = 0; i < triangleCount; ++i) {
		int i0 = triangles[3 * i + 2] + 1;
		int i1 = triangles[3 * i + 1] + 1;
		int i2 = triangles[3 * i + 0] + 1;
		[obj appendFormat:@"f %d/%d/%d %d/%d/%d %d/%d/%d\n", i0, i0, i0, i1, i1, i1, i2, i2, i2];
	}
	[[obj dataUsingEncoding:NSUTF8StringEncoding] writeToFile:objFile atomically:YES];
}

#pragma mark -
#pragma mark Tracking

- (void)featurePoints:(VisageSDK::FDP *)fdp ids:(FeaturePointId *)ids count:(NSInteger)count buffer:(GLKVector4 *)buffer {
	for (int i = 0; i < count; ++i) {
		const VisageSDK::FeaturePoint &fp = fdp->getFP(ids[i].group, ids[i].index);
		buffer[i] = fp.defined ? GLKVector4Make(fp.pos[0], fp.pos[1], fp.pos[2], 1.0f) : GLKVector4Make(0.0, 0.0, 0.0, 1.0);
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
	
	// allocate the buffers
	GLint vertexCount = 0;
	GLint triangleCount = 0;
	for (int i = 0; i < MAXIMUM_NUMBER_OF_FACES; ++i) {
		if (_trackerStatus[i] == TRACK_STAT_OK) {
			VisageSDK::FaceData &faceData = _faceData[i];
			vertexCount += faceData.faceModelVertexCount;
			triangleCount += faceData.faceModelTriangleCount;
		}
	}
	if (triangleCount) {
		// 1 triangle => 3 lines (6 indices)
		GLint wireframeIndicesCount = triangleCount * 6;
		if (!_wireframeIndices || _wireframeIndicesCount < wireframeIndicesCount) {
			if (_wireframeIndices) {
				free(_wireframeIndices);
			}
			_wireframeIndices = (typeof(_wireframeIndices))malloc(wireframeIndicesCount * sizeof(*_wireframeIndices));
			_wireframeIndicesCount = wireframeIndicesCount;
		}
	}
	if (vertexCount) {
		if (!_vertices || _vertexCount < vertexCount) {
			if (_vertices) {
				free(_vertices);
			}
			_vertices = (typeof(_vertices))malloc(vertexCount * sizeof(*_vertices));
			_vertexCount = vertexCount;
		}
	}
}

#pragma mark -
#pragma mark Calculations

- (GLKMatrix4)viewMatrix {
	return GLKMatrix4MakeLookAt(0, 0, 0, 0, 0, -1, 0, 1, 0);
}

- (GLKMatrix4)projectionMatrix:(const VisageSDK::FaceData &)faceData {
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
	GLfloat frustum_x = x_offset * frustum_near / faceData.cameraFocus;
	GLfloat frustum_y = y_offset * frustum_near / faceData.cameraFocus;
	//GLKMatrix4 projectionMatrix = GLKMatrix4MakeFrustum(-frustum_x,frustum_x,-frustum_y,frustum_y,frustum_near,frustum_far);
	GLKMatrix4 projectionMatrix = GLKMatrix4MakeFrustum(-frustum_x, frustum_x, frustum_y, -frustum_y,frustum_near,frustum_far); // show upside-down
	return projectionMatrix;
}

- (GLKMatrix4)modelMatrix:(const VisageSDK::FaceData &)faceData {
	// model matrix
	const float *r = faceData.faceRotation;
	const float *t = faceData.faceTranslation;
	//because x and z axes in OpenGL are opposite from the ones used by visage
	GLKMatrix4 modelMatrix = GLKMatrix4MakeTranslation(-t[0], t[1], -t[2]);
	modelMatrix = GLKMatrix4RotateY(modelMatrix, r[1]);
	modelMatrix = GLKMatrix4RotateX(modelMatrix, r[0]);
	modelMatrix = GLKMatrix4RotateZ(modelMatrix, r[2]);
	return modelMatrix;
}

- (void)buildVertices:(Vertex *)vertices from:(const VisageSDK::FaceData &)faceData {
	// set initial values
	for (int j = 0; j < faceData.faceModelVertexCount; ++j) {
		Vertex &v = vertices[j];
		v.position = GLKVector4MakeWithVector3(GLKVector3MakeWithArray(&faceData.faceModelVertices[j * 3]), 1.0);
		v.normal = GLKVector4Make(0.0, 0.0, 0.0, 0.0);
	}
	// calculate normals
	for (int j = 0; j < faceData.faceModelTriangleCount; ++j) {
		Vertex &v0 = vertices[ faceData.faceModelTriangles[3 * j + 2] ];
		Vertex &v1 = vertices[ faceData.faceModelTriangles[3 * j + 1] ];
		Vertex &v2 = vertices[ faceData.faceModelTriangles[3 * j + 0] ];
		GLKVector4 n = GLKVector4CrossProduct(GLKVector4Subtract(v1.position, v0.position), GLKVector4Subtract(v2.position, v0.position));
		v0.normal = GLKVector4Add(v0.normal, n);
		v1.normal = GLKVector4Add(v1.normal, n);
		v2.normal = GLKVector4Add(v2.normal, n);
	}
	// normalize the normals
	for (int j = 0; j < faceData.faceModelVertexCount; ++j) {
		Vertex &v = vertices[j];
		v.normal = GLKVector4Normalize(v.normal);
	}
}

- (void)buildWireframeIndices:(GLushort *)wireframeIndices from:(const VisageSDK::FaceData &)faceData {
	// go through all triangles
	for (int j = 0; j < faceData.faceModelTriangleCount; ++j) {
		// 3 indices for each triangle
		GLushort i0 = (GLushort)faceData.faceModelTriangles[3 * j + 2];
		GLushort i1 = (GLushort)faceData.faceModelTriangles[3 * j + 1];
		GLushort i2 = (GLushort)faceData.faceModelTriangles[3 * j + 0];
		
		// wireframe model
		if (i0 > i1) {
			swap(i0, i1);
		}
		if (i0 > i2) {
			swap(i0, i2);
		}
		if (i1 > i2) {
			swap(i1, i2);
		}
		GLushort lineIndices[] = { i0, i1, i1, i2, i0, i2 };
		memcpy(&wireframeIndices[6 * j], lineIndices, sizeof(lineIndices));
	}
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
	
	// go through all detected faces
	GLint verticesOffset = 0;
	GLint wireframeIndicesOffset = 0;
	for (int i = 0; i < MAXIMUM_NUMBER_OF_FACES; ++i) {
		// check status
		if (_trackerStatus[i] == TRACK_STAT_OK) {
			VisageSDK::FaceData &faceData = _faceData[i];
			Vertex *vertices = _vertices + verticesOffset;
			GLushort *wireframeIndices = _wireframeIndices + wireframeIndicesOffset;
			[self buildVertices:vertices from:faceData];
			[self buildWireframeIndices:wireframeIndices from:faceData];
			
			// shaders parameters
			glVertexAttribPointer(_attributePosition, 4, GL_FLOAT, GL_FALSE, sizeof(*vertices), &vertices[0].position);
			glVertexAttribPointer(_attributeNormal, 4, GL_FLOAT, GL_FALSE, sizeof(*vertices), &vertices[0].normal);
			glUniform4f(_uniformObjectColor, 1.0, 0.5, 0.3, 1.0);
			glUniform4f(_uniformLightColor, 1.0, 1.0, 1.0, 1.0);
			glUniform4f(_uniformViewPosition, 0.0, 0.0, 0.0, 1.0);
			glUniform4f(_uniformLightPosition, 0.0, 0.15, 0.5, 1.0);
			glUniformMatrix4fv(_uniformModelMatrix, 1, 0, [self modelMatrix:faceData].m);
			glUniformMatrix4fv(_uniformViewMatrix, 1, 0, [self viewMatrix].m);
			glUniformMatrix4fv(_uniformProjectionMatrix, 1, 0, [self projectionMatrix:faceData].m);
			
			// rendering depends on current view mode
			if (_mode == VisageFilterViewModeFeaturePoints) {
				// feature points
				glVertexAttribPointer(_attributePosition, 4, GL_FLOAT, 0, 0, _featurePoints);
				glUniform4f(_uniformObjectColor, 0.0, 1.0, 0.0, 1.0);
				VisageSDK::FDP *fdp = faceData.featurePoints3DRelative;
				int offset = 0;
				for (int n = 0; n < sizeof(featurePointsElements) / sizeof(*featurePointsElements); ++n) {
					FeaturePoints &element = featurePointsElements[n];
					[self featurePoints:fdp ids:element.ids count:element.count buffer:_featurePoints + offset];
					glDrawArrays(GL_LINE_STRIP, offset, element.count);
					offset += element.count;
				}
				glDrawArrays(GL_POINTS, 0, offset);
			}
			else if (_mode == VisageFilterViewModeWireframe) {
				// wireframe
				glUniform4f(_uniformObjectColor, 0.0, 0.0, 1.0, 1.0);
				glDrawElements(GL_LINES, faceData.faceModelTriangleCount * 6, GL_UNSIGNED_SHORT, _wireframeIndices);
			}
			else if (_mode == VisageFilterViewModeMesh) {
				// 3d mesh
				glDrawElements(GL_TRIANGLES, faceData.faceModelTriangleCount * 3, GL_UNSIGNED_INT, faceData.faceModelTriangles);
			}
			else {
				NSAssert(NO, @"Unknown view mode.");
			}
			
			// move to the next face data
			verticesOffset += faceData.faceModelVertexCount;
			wireframeIndicesOffset += faceData.faceModelTriangleCount * 6;
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
