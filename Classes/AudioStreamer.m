//
//  AudioStreamer.m
//  StreamingAudioPlayer
//
//  Created by Matt Gallagher on 27/09/08.
//  Copyright 2008 Matt Gallagher. All rights reserved.
//
//  Permission is given to use this source code file, free of charge, in any
//  project, commercial or otherwise, entirely at your risk, with the condition
//  that any redistribution (in part or whole) of source code must retain
//  this copyright and permission notice. Attribution in compiled projects is
//  appreciated but not required.
//

#import "AudioStreamer.h"
#if TARGET_OS_IPHONE
#import "iPhoneStreamingPlayerAppDelegate.h"
#import <CFNetwork/CFNetwork.h>
//#import "UIDevice+Hardware.h"
#define kCFCoreFoundationVersionNumber_MIN 550.32
#else
#define kCFCoreFoundationVersionNumber_MIN 550.00
#endif

#define BitRateEstimationMaxPackets 5000
#define BitRateEstimationMinPackets 50

NSString * const ASStatusChangedNotification = @"ASStatusChangedNotification";
NSString * const ASPresentAlertWithTitleNotification = @"ASPresentAlertWithTitleNotification";

//#if TARGET_OS_IPHONE	
static AudioStreamer *__streamer = nil;
//#endif

NSString * const AS_NO_ERROR_STRING = @"No error.";
NSString * const AS_FILE_STREAM_GET_PROPERTY_FAILED_STRING = @"File stream get property failed.";
NSString * const AS_FILE_STREAM_SEEK_FAILED_STRING = @"File stream seek failed.";
NSString * const AS_FILE_STREAM_PARSE_BYTES_FAILED_STRING = @"Parse bytes failed.";
NSString * const AS_FILE_STREAM_OPEN_FAILED_STRING = @"Open audio file stream failed.";
NSString * const AS_FILE_STREAM_CLOSE_FAILED_STRING = @"Close audio file stream failed.";
NSString * const AS_AUDIO_QUEUE_CREATION_FAILED_STRING = @"Audio queue creation failed.";
NSString * const AS_AUDIO_QUEUE_BUFFER_ALLOCATION_FAILED_STRING = @"Audio buffer allocation failed.";
NSString * const AS_AUDIO_QUEUE_ENQUEUE_FAILED_STRING = @"Queueing of audio buffer failed.";
NSString * const AS_AUDIO_QUEUE_ADD_LISTENER_FAILED_STRING = @"Audio queue add listener failed.";
NSString * const AS_AUDIO_QUEUE_REMOVE_LISTENER_FAILED_STRING = @"Audio queue remove listener failed.";
NSString * const AS_AUDIO_QUEUE_START_FAILED_STRING = @"Audio queue start failed.";
NSString * const AS_AUDIO_QUEUE_BUFFER_MISMATCH_STRING = @"Audio queue buffers don't match.";
NSString * const AS_AUDIO_QUEUE_DISPOSE_FAILED_STRING = @"Audio queue dispose failed.";
NSString * const AS_AUDIO_QUEUE_PAUSE_FAILED_STRING = @"Audio queue pause failed.";
NSString * const AS_AUDIO_QUEUE_STOP_FAILED_STRING = @"Audio queue stop failed.";
NSString * const AS_AUDIO_DATA_NOT_FOUND_STRING = @"No audio data found.";
NSString * const AS_AUDIO_QUEUE_FLUSH_FAILED_STRING = @"Audio queue flush failed.";
NSString * const AS_GET_AUDIO_TIME_FAILED_STRING = @"Audio queue get current time failed.";
NSString * const AS_AUDIO_STREAMER_FAILED_STRING = @"Audio playback failed";
NSString * const AS_NETWORK_CONNECTION_FAILED_STRING = @"Network connection failed";
NSString * const AS_AUDIO_BUFFER_TOO_SMALL_STRING = @"Audio packets are larger than kAQDefaultBufSize.";

@interface AudioStreamer ()
@property (readwrite) AudioStreamerState state;

- (void)handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream
                     fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID
                                  ioFlags:(UInt32 *)ioFlags;

- (void)handleAudioPackets:(const void *)inInputData
               numberBytes:(UInt32)inNumberBytes
             numberPackets:(UInt32)inNumberPackets
        packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions;

- (void)handleBufferCompleteForQueue:(AudioQueueRef)inAQ
                              buffer:(AudioQueueBufferRef)inBuffer;

- (void)handlePropertyChangeForQueue:(AudioQueueRef)inAQ
                          propertyID:(AudioQueuePropertyID)inID;

#if TARGET_OS_IPHONE
- (void)handleInterruptionChangeToState:(AudioQueuePropertyID)inInterruptionState;
#endif
// pur
- (void)handlePropertyChangeForPur;

- (void)internalSeekToTime:(double)newSeekTime;
- (void)enqueueBuffer;
- (void)handleReadFromStream:(CFReadStreamRef)aStream
                   eventType:(CFStreamEventType)eventType;
- (void)togglePause;
- (void)fadein;
- (void)fadeout;
@end

#pragma mark Audio Callback Function Prototypes

void MyAudioQueueOutputCallback(void* inClientData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer);
void MyAudioQueueIsRunningCallback(void *inUserData, AudioQueueRef inAQ, AudioQueuePropertyID inID);
void MyPropertyListenerProc(void *							inClientData,
                            AudioFileStreamID				inAudioFileStream,
                            AudioFileStreamPropertyID		inPropertyID,
                            UInt32 *						ioFlags);
void MyPacketsProc(void *							inClientData,
                   UInt32							inNumberBytes,
                   UInt32							inNumberPackets,
                   const void *                     inInputData,
                   AudioStreamPacketDescription     *inPacketDescriptions);
OSStatus MyEnqueueBuffer(AudioStreamer* myData);

#if TARGET_OS_IPHONE			
void MyAudioSessionInterruptionListener(void *inClientData, UInt32 inInterruptionState);
#endif

#pragma mark Audio Callback Function Implementations

//
// MyPropertyListenerProc
//
// Receives notification when the AudioFileStream has audio packets to be
// played. In response, this function creates the AudioQueue, getting it
// ready to begin playback (playback won't begin until audio packets are
// sent to the queue in MyEnqueueBuffer).
//
// This function is adapted from Apple's example in AudioFileStreamExample with
// kAudioQueueProperty_IsRunning listening added.
//
void MyPropertyListenerProc(void *							inClientData,
                            AudioFileStreamID				inAudioFileStream,
                            AudioFileStreamPropertyID		inPropertyID,
                            UInt32 *						ioFlags)
{	
	// this is called by audio file stream when it finds property values
	AudioStreamer* streamer = (__bridge AudioStreamer *)inClientData;
	[streamer
     handlePropertyChangeForFileStream:inAudioFileStream
     fileStreamPropertyID:inPropertyID
     ioFlags:ioFlags];
}

//
// MyPacketsProc
//
// When the AudioStream has packets to be played, this function gets an
// idle audio buffer and copies the audio packets into it. The calls to
// MyEnqueueBuffer won't return until there are buffers available (or the
// playback has been stopped).
//
// This function is adapted from Apple's example in AudioFileStreamExample with
// CBR functionality added.
//
void MyPacketsProc(void *							inClientData,
                   UInt32							inNumberBytes,
                   UInt32							inNumberPackets,
                   const void *					inInputData,
                   AudioStreamPacketDescription	*inPacketDescriptions)
{
	// this is called by audio file stream when it finds packets of audio
	AudioStreamer* streamer = (__bridge AudioStreamer *)inClientData;
	[streamer
     handleAudioPackets:inInputData
     numberBytes:inNumberBytes
     numberPackets:inNumberPackets
     packetDescriptions:inPacketDescriptions];
}

//
// MyAudioQueueOutputCallback
//
// Called from the AudioQueue when playback of specific buffers completes. This
// function signals from the AudioQueue thread to the AudioStream thread that
// the buffer is idle and available for copying data.
//
// This function is unchanged from Apple's example in AudioFileStreamExample.
//
void MyAudioQueueOutputCallback(void*					inClientData, 
                                AudioQueueRef			inAQ, 
                                AudioQueueBufferRef		inBuffer)
{
	// this is called by the audio queue when it has finished decoding our data. 
	// The buffer is now free to be reused.
	AudioStreamer* streamer = (__bridge AudioStreamer*)inClientData;
	[streamer handleBufferCompleteForQueue:inAQ buffer:inBuffer];
}

//
// MyAudioQueueIsRunningCallback
//
// Called from the AudioQueue when playback is started or stopped. This
// information is used to toggle the observable "isPlaying" property and
// set the "finished" flag.
//
void MyAudioQueueIsRunningCallback(void *inUserData, AudioQueueRef inAQ, AudioQueuePropertyID inID)
{
	AudioStreamer* streamer = (__bridge AudioStreamer *)inUserData;
	[streamer handlePropertyChangeForQueue:inAQ propertyID:inID];
}

#if TARGET_OS_IPHONE			
//
// MyAudioSessionInterruptionListener
//
// Invoked if the audio session is interrupted (like when the phone rings)
//
void MyAudioSessionInterruptionListener(void *inClientData, UInt32 inInterruptionState)
{
	//AudioStreamer* streamer = (AudioStreamer *)inClientData;
	//[streamer handleInterruptionChangeToState:inInterruptionState];
	[__streamer handleInterruptionChangeToState:inInterruptionState];
}
#endif

#pragma mark CFReadStream Callback Function Implementations

//
// ReadStreamCallBack
//
// This is the callback for the CFReadStream from the network connection. This
// is where all network data is passed to the AudioFileStream.
//
// Invoked when an error occurs, the stream ends or we have data to read.
//
void ASReadStreamCallBack
(
 CFReadStreamRef aStream,
 CFStreamEventType eventType,
 void* inClientInfo
 );
void ASReadStreamCallBack
(
 CFReadStreamRef aStream,
 CFStreamEventType eventType,
 void* inClientInfo
 )
{
	AudioStreamer* streamer = (__bridge AudioStreamer *)inClientInfo;
	[streamer handleReadFromStream:aStream eventType:eventType];
}


// ------------------------------------------------------------------------------------------------

//static int LoadFrame(FILE * fp,long frame_bytes,BYTE  frame_buffer)
//{
//    if (fp)
//    {
//        if (fread(& frame_buffer, 1, frame_bytes, fp) == frame_bytes)
//        {
//            return 1;
//        }
//    }
//    
//    return 0;
//}

// ------------------------------------------------------------------------------------------------
//后续实现seek 功能
//static int SeekPosition(FILE * fp, long nPositionMS)
//{
//    if (fp)
//    {
//        if (nPositionMS >= 0)
//        {
//            nPositionMS = (nPositionMS / 20) * frame_bytes + sizeof(pure_header);
//            
//            if (0 == fseek(fp, nPositionMS, SEEK_SET))
//            {
//                Pure_SeekReset(pCODEC);
//            }
//            
//            return 1;
//        }
//    }
//    
//    return 0;
//}

@implementation AudioStreamer

@synthesize errorCode;
@synthesize state;
@synthesize bitRate;
@synthesize httpHeaders;

@synthesize stopReason;
@synthesize numberOfChannels;
@synthesize vbr;

#pragma pur
- (int)LoadHeader
{
    if (stream)
    {
        if (CFReadStreamRead(stream, (UInt8 *)&pure_header, (CFIndex)sizeof(pure_header)) == sizeof(pure_header))
            //fread(& pure_header, 1, sizeof(pure_header), fp) == sizeof(pure_header)
        {
            if (Pure_CheckHeader(&pure_header))
            {
                frame_bytes = pure_header.m_ucBPS * 5 + 4;
                durationMS  = pure_header.m_dwPCMLENGTH / (48 * 4);
                return 1;
            }
        }
    }
    
    return 0;
}
//
// initWithURL
//
// Init method for the object.
//
- (id)initWithURL:(NSURL *)aURL
{
	self = [super init];
	if (self != nil)
	{
		url = aURL;
        
        isfile = [aURL isFileURL];
        durationMS = 0;
        pCODEC = 0;
        reconnectTimes = 0;
	}
	return self;
}

//
// dealloc
//
// Releases instance memory.
//
- (void)dealloc
{
	[self stop];
    //AudioQueueDispose(audioQueue,false);
    //audioFileStream 
    //asbd
    //internalThread 
    //AudioQueueBufferRef audioQueueBuffer[kNumAQBufs]; 
    //AudioStreamPacketDescription packetDescs[kAQMaxPacketDescs]; 
    //bool inuse[kNumAQBufs]; 
    //pthread_mutex_t queueBuffersMutex;
    //pthread_cond_t queueBufferReadyCondition; 
    //CFReadStreamRef stream; 
    //NSNotificationCenter *notificationCenter; 
    //structPURE_HEADER pure_header   ;
    //free(pure_header);
    //BYTE  frame_buffer[644 ];  
    
    //struct PURE_CODEC_HANDLE * pCODEC;
    free(pCODEC);
    //#ifdef SHOUTCAST_METADATA
    //	[metaDataString release];
    //#endif
}

//
// bufferFillPercentage
//
// returns a value between 0 and 1 that represents how full the buffer is
//
-(double)bufferFillPercentage
{
	return (double)buffersUsed/(double)(kNumAQBufs - 1);
}


//
// isFinishing
//
// returns YES if the audio has reached a stopping condition.
//
- (BOOL)isFinishing
{
	@synchronized (self)
	{
		if ((errorCode != AS_NO_ERROR && state != AS_INITIALIZED) ||
			((state == AS_STOPPING || state == AS_STOPPED) &&
             stopReason != AS_STOPPING_TEMPORARILY))
		{
			return YES;
		}
	}
	
	return NO;
}

//
// runLoopShouldExit
//
// returns YES if the run loop should exit.
//
- (BOOL)runLoopShouldExit
{
	@synchronized(self)
	{
        if (reConnect) {
            return NO;
        }
		if (errorCode != AS_NO_ERROR ||
			(state == AS_STOPPED &&
             stopReason != AS_STOPPING_TEMPORARILY))
		{
			return YES;
		}
	}
	
	return NO;
}

//
// stringForErrorCode:
//
// Converts an error code to a string that can be localized or presented
// to the user.
//
// Parameters:
//    anErrorCode - the error code to convert
//
// returns the string representation of the error code
//
+ (NSString *)stringForErrorCode:(AudioStreamerErrorCode)anErrorCode
{
	switch (anErrorCode)
	{
		case AS_NO_ERROR:
			return AS_NO_ERROR_STRING;
		case AS_FILE_STREAM_GET_PROPERTY_FAILED:
			return AS_FILE_STREAM_GET_PROPERTY_FAILED_STRING;
		case AS_FILE_STREAM_SEEK_FAILED:
			return AS_FILE_STREAM_SEEK_FAILED_STRING;
		case AS_FILE_STREAM_PARSE_BYTES_FAILED:
			return AS_FILE_STREAM_PARSE_BYTES_FAILED_STRING;
		case AS_AUDIO_QUEUE_CREATION_FAILED:
			return AS_AUDIO_QUEUE_CREATION_FAILED_STRING;
		case AS_AUDIO_QUEUE_BUFFER_ALLOCATION_FAILED:
			return AS_AUDIO_QUEUE_BUFFER_ALLOCATION_FAILED_STRING;
		case AS_AUDIO_QUEUE_ENQUEUE_FAILED:
			return AS_AUDIO_QUEUE_ENQUEUE_FAILED_STRING;
		case AS_AUDIO_QUEUE_ADD_LISTENER_FAILED:
			return AS_AUDIO_QUEUE_ADD_LISTENER_FAILED_STRING;
		case AS_AUDIO_QUEUE_REMOVE_LISTENER_FAILED:
			return AS_AUDIO_QUEUE_REMOVE_LISTENER_FAILED_STRING;
		case AS_AUDIO_QUEUE_START_FAILED:
			return AS_AUDIO_QUEUE_START_FAILED_STRING;
		case AS_AUDIO_QUEUE_BUFFER_MISMATCH:
			return AS_AUDIO_QUEUE_BUFFER_MISMATCH_STRING;
		case AS_FILE_STREAM_OPEN_FAILED:
			return AS_FILE_STREAM_OPEN_FAILED_STRING;
		case AS_FILE_STREAM_CLOSE_FAILED:
			return AS_FILE_STREAM_CLOSE_FAILED_STRING;
		case AS_AUDIO_QUEUE_DISPOSE_FAILED:
			return AS_AUDIO_QUEUE_DISPOSE_FAILED_STRING;
		case AS_AUDIO_QUEUE_PAUSE_FAILED:
			return AS_AUDIO_QUEUE_DISPOSE_FAILED_STRING;
		case AS_AUDIO_QUEUE_FLUSH_FAILED:
			return AS_AUDIO_QUEUE_FLUSH_FAILED_STRING;
		case AS_AUDIO_DATA_NOT_FOUND:
			return AS_AUDIO_DATA_NOT_FOUND_STRING;
		case AS_GET_AUDIO_TIME_FAILED:
			return AS_GET_AUDIO_TIME_FAILED_STRING;
		case AS_NETWORK_CONNECTION_FAILED:
			return AS_NETWORK_CONNECTION_FAILED_STRING;
		case AS_AUDIO_QUEUE_STOP_FAILED:
			return AS_AUDIO_QUEUE_STOP_FAILED_STRING;
		case AS_AUDIO_STREAMER_FAILED:
			return AS_AUDIO_STREAMER_FAILED_STRING;
		case AS_AUDIO_BUFFER_TOO_SMALL:
			return AS_AUDIO_BUFFER_TOO_SMALL_STRING;
		default:
			return AS_AUDIO_STREAMER_FAILED_STRING;
	}
	
	return AS_AUDIO_STREAMER_FAILED_STRING;
}

//
// presentAlertWithTitle:message:
//
// Common code for presenting error dialogs
//
// Parameters:
//    title - title for the dialog
//    message - main test for the dialog
//
//- (void)presentAlertWithTitle:(NSString*)title message:(NSString*)message
//{
//	NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:title, @"title", message, @"message", nil];
//	NSNotification *notification =
//	[NSNotification
//	 notificationWithName:ASPresentAlertWithTitleNotification
//	 object:self
//	 userInfo:userInfo];
//	[[NSNotificationCenter defaultCenter]
//	 postNotification:notification];
//}

//
// failWithErrorCode:
//
// Sets the playback state to failed and logs the error.
//
// Parameters:
//    anErrorCode - the error condition
//
- (void)failWithErrorCode:(AudioStreamerErrorCode)anErrorCode
{
	@synchronized(self)
	{
		if (errorCode != AS_NO_ERROR)
		{
			// Only set the error once.
			return;
		}
		
		errorCode = anErrorCode;
        
		if (err)
		{
			char *errChars = (char *)&err;
			DLog(@"%@ err: %c%c%c%c %d\n",
                 [AudioStreamer stringForErrorCode:anErrorCode],
                 errChars[3], errChars[2], errChars[1], errChars[0],
                 (int)err);
		}
		else
		{
			DLog(@"%@", [AudioStreamer stringForErrorCode:anErrorCode]);
		}
        //zzzzzzz
        if (state == AS_PLAYING && anErrorCode == AS_AUDIO_DATA_NOT_FOUND) {
            return;
        }
		if ( state == AS_PAUSED ||
			state == AS_BUFFERING)
		{
			self.state = AS_STOPPING;
			stopReason = AS_STOPPING_ERROR;
			AudioQueueStop(audioQueue, true);
		}
        if (err == AS_AUDIO_QUEUE_START_FAILED) {
            self.state = AS_INITIALIZED;
            DLog(@"failWithErrorCode:AS_AUDIO_QUEUE_START_FAILED ");
        }
        
        //        [self presentAlertWithTitle:NSLocalizedStringFromTable(@"File Error", @"Errors", nil)
        //                            message:NSLocalizedStringFromTable(@"Unable to configure network read stream.", @"Errors", nil)];
	}
}

//
// mainThreadStateNotification
//
// Method invoked on main thread to send notifications to the main thread's
// notification center.
//
- (void)mainThreadStateNotification
{
	NSNotification *notification =
    [NSNotification
     notificationWithName:ASStatusChangedNotification
     object:self];
	[[NSNotificationCenter defaultCenter]
     postNotification:notification];
}

//
// setState:
//
// Sets the state and sends a notification that the state has changed.
//
// This method
//
// Parameters:
//    anErrorCode - the error condition
//
- (AudioStreamerState)state
{
    @synchronized(self)
	{
        return state;
    }
}

- (void)setState:(AudioStreamerState)aStatus
{
	@synchronized(self)
	{
		if (state != aStatus)
		{
			state = aStatus;
			
			if ([[NSThread currentThread] isEqual:[NSThread mainThread]])
			{
				[self mainThreadStateNotification];
			}
			else
			{
				[self
                 performSelectorOnMainThread:@selector(mainThreadStateNotification)
                 withObject:nil
                 waitUntilDone:NO];
			}
		}
	}
}

//
// isPlaying
//
// returns YES if the audio currently playing.
//
- (BOOL)isPlaying
{
	if (state == AS_PLAYING)
	{
		return YES;
	}
	
	return NO;
}

//
// isPaused
//
// returns YES if the audio currently playing.
//
- (BOOL)isPaused
{
	if (state == AS_PAUSED)
	{
		return YES;
	}
	
	return NO;
}

//
// isWaiting
//
// returns YES if the AudioStreamer is waiting for a state transition of some
// kind.
//
- (BOOL)isWaiting
{
	@synchronized(self)
	{
		if ([self isFinishing] ||
			state == AS_STARTING_FILE_THREAD||
			state == AS_WAITING_FOR_DATA ||
			state == AS_WAITING_FOR_QUEUE_TO_START ||
			state == AS_BUFFERING)
		{
			return YES;
		}
	}
	
	return NO;
}

//
// isIdle
//
// returns YES if the AudioStream is in the AS_INITIALIZED state (i.e.
// isn't doing anything).
//
- (BOOL)isIdle
{
	if (state == AS_INITIALIZED)
	{
		return YES;
	}
	
	return NO;
}

//
// hintForFileExtension:
//
// Generates a first guess for the file type based on the file's extension
//
// Parameters:
//    fileExtension - the file extension
//
// returns a file type hint that can be passed to the AudioFileStream
//
+ (AudioFileTypeID)hintForFileExtension:(NSString *)fileExtension
{
	AudioFileTypeID fileTypeHint = kAudioFileMP3Type;
	if ([fileExtension isEqual:@"mp3"])
	{
		fileTypeHint = kAudioFileMP3Type;
	}
	else if ([fileExtension isEqual:@"wav"])
	{
		fileTypeHint = kAudioFileWAVEType;
	}
	else if ([fileExtension isEqual:@"aifc"])
	{
		fileTypeHint = kAudioFileAIFCType;
	}
	else if ([fileExtension isEqual:@"aiff"])
	{
		fileTypeHint = kAudioFileAIFFType;
	}
	else if ([fileExtension isEqual:@"m4a"])
	{
		fileTypeHint = kAudioFileM4AType;
	}
	else if ([fileExtension isEqual:@"mp4"])
	{
		fileTypeHint = kAudioFileMPEG4Type;
	}
	else if ([fileExtension isEqual:@"caf"])
	{
		fileTypeHint = kAudioFileCAFType;
	}
	else if ([fileExtension isEqual:@"aac"])
	{
		fileTypeHint = kAudioFileAAC_ADTSType;
	}
    else if ([fileExtension isEqual:@"pur"])
	{
		fileTypeHint = kAudioFilePUREType;
	}
	return fileTypeHint;
}

//
// hintForMIMEType
//
// Make a more informed guess on the file type based on the MIME type
//
// Parameters:
//    mimeType - the MIME type
//
// returns a file type hint that can be passed to the AudioFileStream
//
+ (AudioFileTypeID)hintForMIMEType:(NSString *)mimeType
{
	AudioFileTypeID fileTypeHint = kAudioFileMP3Type;
	if ([mimeType isEqual:@"audio/mpeg"])
	{
		fileTypeHint = kAudioFileMP3Type;
	}
	else if ([mimeType isEqual:@"audio/x-wav"])
	{
		fileTypeHint = kAudioFileWAVEType;
	}
	else if ([mimeType isEqual:@"audio/x-aiff"])
	{
		fileTypeHint = kAudioFileAIFFType;
	}
	else if ([mimeType isEqual:@"audio/x-m4a"])
	{
		fileTypeHint = kAudioFileM4AType;
	}
	else if ([mimeType isEqual:@"audio/mp4"])
	{
		fileTypeHint = kAudioFileMPEG4Type;
	}
	else if ([mimeType isEqual:@"audio/x-caf"])
	{
		fileTypeHint = kAudioFileCAFType;
	}
	else if ([mimeType isEqual:@"audio/aac"] || [mimeType isEqual:@"audio/aacp"])
	{
		fileTypeHint = kAudioFileAAC_ADTSType;
	}
    else if ([mimeType isEqual:@"audio/x-pur"])
    {
        fileTypeHint = kAudioFilePUREType;
    }
	return fileTypeHint;
}

//
// openReadStream
//
// Open the audioFileStream to parse data and the fileHandle as the data
// source.
//
- (BOOL)openReadStream
{
    if (stream) {
        DLog(@"network stream still living ");
    }
#if TARGET_OS_IPHONE
    iPhoneStreamingPlayerAppDelegate *appdelegate = (iPhoneStreamingPlayerAppDelegate*)[[UIApplication sharedApplication] delegate];
    int status = appdelegate.networkStatus;
    
    switch (status) {
        case 2:
            break;
        case 0:
            return NO;
            break;    
        default:
            break;
    }
#endif
    
	@synchronized(self)
	{
		NSAssert([[NSThread currentThread] isEqual:internalThread],
                 @"File stream download must be started on the internalThread");
		NSAssert(stream == nil, @"Download stream already initialized");
		
		//
		// Create the HTTP GET request
		//
        if (!url) {
            return NO;   
        }else{
            if (!isfile) {
                CFHTTPMessageRef message= CFHTTPMessageCreateRequest(NULL, (CFStringRef)@"GET", (__bridge CFURLRef)url, kCFHTTPVersion1_1);
                
                // If we are creating this request to seek to a location, set the
                // requested byte range in the headers.
                //
                if (fileLength > 0 && seekByteOffset > 0)
                {
                    CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Range"),
                                                     (__bridge CFStringRef)[NSString stringWithFormat:@"bytes=%ld-%ld", seekByteOffset, fileLength - 1]);
                    discontinuous = vbr;
                    DLog(@"http Range bytes=%ld-%ld", (long)seekByteOffset, (long)fileLength - 1);
                }
                
                //
                // Create the read stream that will receive data from the HTTP request
                //
                stream = CFReadStreamCreateForHTTPRequest(NULL, message);
                CFRelease(message);
                
                //
                // Enable stream redirection
                //
                if (CFReadStreamSetProperty(
                                            stream,
                                            kCFStreamPropertyHTTPShouldAutoredirect,
                                            kCFBooleanTrue) == false)
                {
                    //[self presentAlertWithTitle:NSLocalizedStringFromTable(@"File Error", @"Errors", nil)
                    //					message:NSLocalizedStringFromTable(@"Unable to configure network read stream.", @"Errors", nil)];
                    return NO;
                }
                
                //
                // Handle proxies
                //
                CFDictionaryRef proxySettings = CFNetworkCopySystemProxySettings();
                CFReadStreamSetProperty(stream, kCFStreamPropertyHTTPProxy, proxySettings);
                CFRelease(proxySettings);                
                
                //
                // Handle SSL connections
                //
                if( [[url absoluteString] rangeOfString:@"https"].location != NSNotFound )
                {
                    NSDictionary *sslSettings =
                    [NSDictionary dictionaryWithObjectsAndKeys:
                     (NSString *)kCFStreamSocketSecurityLevelNegotiatedSSL, kCFStreamSSLLevel,
                     [NSNumber numberWithBool:YES], kCFStreamSSLAllowsExpiredCertificates,
                     [NSNumber numberWithBool:YES], kCFStreamSSLAllowsExpiredRoots,
                     [NSNumber numberWithBool:YES], kCFStreamSSLAllowsAnyRoot,
                     [NSNumber numberWithBool:NO], kCFStreamSSLValidatesCertificateChain,
                     [NSNull null], kCFStreamSSLPeerName,
                     nil];
                    
                    CFReadStreamSetProperty(stream, kCFStreamPropertySSLSettings, (__bridge CFDictionaryRef)sslSettings);
                }
            }
        }
        
        
		//
		// We're now ready to receive data
		//
		self.state = AS_WAITING_FOR_DATA;
        
		//
		// Open the stream
		//
		if (!CFReadStreamOpen(stream))
		{
			CFRelease(stream);
			//[self presentAlertWithTitle:NSLocalizedStringFromTable(@"File Error", @"Errors", nil)
			//					message:NSLocalizedStringFromTable(@"Unable to configure network read stream.", @"Errors", nil)];
			return NO;
		}
		
		//
		// Set our callback function to receive the data
		//
		CFStreamClientContext context = {0, (__bridge void *)(self), NULL, NULL, NULL};
		CFReadStreamSetClient(
                              stream,
                              kCFStreamEventNone|kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered|kCFStreamEventOpenCompleted,
                              ASReadStreamCallBack,
                              &context);
		CFReadStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
	}
	
	return YES;
}

//
// startInternal
//
// This is the start method for the AudioStream thread. This thread is created
// because it will be blocked when there are no audio buffers idle (and ready
// to receive audio data).
//
// Activity in this thread:
//	- Creation and cleanup of all AudioFileStream and AudioQueue objects
//	- Receives data from the CFReadStream
//	- AudioFileStream processing
//	- Copying of data from AudioFileStream into audio buffers
//  - Stopping of the thread because of end-of-file
//	- Stopping due to error or failure
//
// Activity *not* in this thread:
//	- AudioQueue playback and notifications (happens in AudioQueue thread)
//  - Actual download of NSURLConnection data (NSURLConnection's thread)
//	- Creation of the AudioStreamer (other, likely "main" thread)
//	- Invocation of -start method (other, likely "main" thread)
//	- User/manual invocation of -stop (other, likely "main" thread)
//
// This method contains bits of the "main" function from Apple's example in
// AudioFileStreamExample.
//
- (void)startInternal
{
	@autoreleasepool {
        
		@synchronized(self)
		{
			if (state != AS_STARTING_FILE_THREAD)
			{
				if (state != AS_STOPPING &&
					state != AS_STOPPED)
				{
					DLog(@"### Not starting audio thread. State code is: %u", state);
				}
				self.state = AS_INITIALIZED;
				return;
			}
			
#if TARGET_OS_IPHONE			
			//
			// Set the audio session category so that we continue to play if the
			// iPhone/iPod auto-locks.
			//
			AudioSessionInitialize (
                                    NULL,                          // 'NULL' to use the default (main) run loop
                                    NULL,                          // 'NULL' to use the default run loop mode
                                    MyAudioSessionInterruptionListener,  // a reference to your interruption callback
                                    (__bridge void *)(self)        // data to pass to your interruption listener callback
                                    );
			UInt32 sessionCategory = kAudioSessionCategory_MediaPlayback;
			AudioSessionSetProperty (
                                     kAudioSessionProperty_AudioCategory,
                                     sizeof (sessionCategory),
                                     &sessionCategory
                                     );
			AudioSessionSetActive(true);
			
#endif
            __streamer = self;
			// initialize a mutex and condition so that we can block on buffers in use.
			pthread_mutex_init(&queueBuffersMutex, NULL);
			pthread_cond_init(&queueBufferReadyCondition, NULL);
			
            int times=0;
            while (![self openReadStream]) {
                if (++times > 3) {
                    DLog(@"openReadStream 3 times!,now clean");
                    
                    goto cleanup;
                }
            }
            //            if (![self openReadStream])
            //            {
            //                goto cleanup;
            //            }
		}
		
		//
		// Process the run loop until playback is finished or failed.
		//
		BOOL isRunning = YES;
		do
		{
			isRunning = [[NSRunLoop currentRunLoop]
                         runMode:NSDefaultRunLoopMode
                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
            if (state == AS_STOPPED) {
                goto cleanup;
            }
            NSDate *curTime=[NSDate date];
            if (state == AS_STOPPED) {
                goto cleanup;
            }
            if ([curTime timeIntervalSinceDate:lastRecivedTime] >20) {
                [self seekToTime:lastProgress];
                lastRecivedTime = curTime;
                DLog(@"20s no data,seek cur pos");
            }
			
			@synchronized(self) {
				if (seekWasRequested) {
					[self internalSeekToTime:requestedSeekTime];
					seekWasRequested = NO;
				}
			}
			
			//
			// If there are no queued buffers, we need to check here since the
			// handleBufferCompleteForQueue:buffer: should not change the state
			// (may not enter the synchronized section).
			//
			if (buffersUsed == 0 && self.state == AS_PLAYING)
			{
				err = AudioQueuePause(audioQueue);
				if (err)
				{
					[self failWithErrorCode:AS_AUDIO_QUEUE_PAUSE_FAILED];
					return;
				}
				self.state = AS_BUFFERING;
			}
            
            
            if (reConnect && isfile == NO) {
                //重新连接
                @synchronized(self){
                    DLog(@"re openReadStream reconnectTimes %d",reconnectTimes);
                    if (reconnectTimes <3) {
                        [self pause];
                        if (stream)
                        {
                            CFReadStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
                            CFReadStreamClose(stream);
                            CFRelease(stream);
                            stream = nil;
                        }
                        if (audioFileStream)
                        {
                            err = AudioFileStreamClose(audioFileStream);
                            audioFileStream = nil;
                            if (err)
                            {
                                [self failWithErrorCode:AS_FILE_STREAM_CLOSE_FAILED];
                            }
                        }
                        //seekByteOffset = 0;
                        httpHeaders = nil;
                        self.state = AS_INITIALIZED;
                        
                        if ([self openReadStream])
                        {
                            
                            self.state = AS_PAUSED;
                            reConnect = NO;
                            [self pause];
                            
                        }else {
                            DLog(@"openReadStream openReadStrea fail");
                            goto cleanup;
                        }
                    }else{
                        
                        DLog(@"re openReadStrea fail 3time");
                        //goto cleanup;
                        
                    }
                    
                    
                    //bytesFilled = 0;
                    //packetsFilled = 0;
                    
                    //packetBufferSize = 0;
                    
                    
                }
            }//finish reConnect
		} while (isRunning && ![self runLoopShouldExit]);
		
    cleanup:
        
		@synchronized(self)
		{
			//
			// Cleanup the read stream if it is still open
			//
			if (stream)
			{
                //fix
                CFReadStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
                (void) CFReadStreamSetClient(stream, kCFStreamEventNone, NULL, NULL);//|kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered|kCFStreamEventOpenCompleted
                
				CFReadStreamClose(stream);
				CFRelease(stream);
				stream = nil;
			}
			
			//
			// Close the audio file strea,
			//
			if (audioFileStream)
			{
				err = AudioFileStreamClose(audioFileStream);
				audioFileStream = nil;
				if (err)
				{
					[self failWithErrorCode:AS_FILE_STREAM_CLOSE_FAILED];
				}
			}
			
			//
			// Dispose of the Audio Queue
			//
			if (audioQueue)
			{                
                for (unsigned int i = 0; i < kNumAQBufs; ++i)
                {
                    AudioQueueFreeBuffer(audioQueue, audioQueueBuffer[i]);
                    //err = AudioQueueAllocateBuffer(audioQueue, packetBufferSize, &audioQueueBuffer[i]);
                    
                }
                
                err = AudioQueueDispose(audioQueue, true);
                audioQueue = nil;
                if (err)
                {
                    [self failWithErrorCode:AS_AUDIO_QUEUE_DISPOSE_FAILED];
                }
				
			}
            
#if TARGET_OS_IPHONE			
			AudioSessionSetActive(false);
#endif
            pthread_mutex_destroy(&queueBuffersMutex);
            pthread_cond_destroy(&queueBufferReadyCondition);
            
			httpHeaders = nil;
            
			bytesFilled = 0;
			packetsFilled = 0;
            seekByteOffset = 0;		
			packetBufferSize = 0;
			self.state = AS_INITIALIZED;
            
            DLog(@"internalThread Destroy");
			internalThread = nil;
		}
	}
}

//
// start
//
// Calls startInternal in a new thread.
//
- (void)start
{
	@synchronized (self)
	{
		if (state == AS_PAUSED)
		{
			[self pause];
		}
		else if (state == AS_INITIALIZED)
		{
			NSAssert([[NSThread currentThread] isEqual:[NSThread mainThread]],
                     @"Playback can only be started from the main thread.");
			notificationCenter = [NSNotificationCenter defaultCenter];
			self.state = AS_STARTING_FILE_THREAD;
            reConnect = NO;
			internalThread = [[NSThread alloc] initWithTarget:self
                                                     selector:@selector(startInternal)
                                                       object:nil];
			[internalThread setName:@"InternalThread"];
			[internalThread start];
		}
	}
}


// internalSeekToTime:
//
// Called from our internal runloop to reopen the stream at a seeked location
//
- (void)internalSeekToTime:(double)newSeekTime
{
	if ([self calculatedBitRate] == 0.0 || fileLength <= 0)
	{
		return;
	}
	//需要算range
    if (fileTypeHint == kAudioFilePUREType) {
        long frameCount= (long)newSeekTime*1000/20;
        
        seekByteOffset = (CFIndex)sizeof(pure_header)+frameCount*324;
        DLog(@"%ld seaktime:%f", (long)seekByteOffset, newSeekTime);
        bytesFilled = 0;
        memset(frame_buffer, 0, sizeof(frame_buffer));
        
        seekTime = newSeekTime;
    }else{
        // 原来的实现，使用native codec
        // Calculate the byte offset for seeking
        //
        seekByteOffset = dataOffset +
		(newSeekTime / self.duration) * (fileLength - dataOffset);
		
        //
        // Attempt to leave 1 useful packet at the end of the file (although in
        // reality, this may still seek too far if the file has a long trailer).
        //
        if (seekByteOffset > fileLength - 2 * packetBufferSize)
        {
            seekByteOffset = fileLength - 2 * packetBufferSize;
        }
        //
        // Store the old time from the audio queue and the time that we're seeking
        // to so that we'll know the correct time progress after seeking.
        //
        seekTime = newSeekTime;
        //
        // Attempt to align the seek with a packet boundary
        //
        double calculatedBitRate = [self calculatedBitRate];
        if (packetDuration > 0 &&
            calculatedBitRate > 0 )
        {
            UInt32 ioFlags = 0;
            SInt64 packetAlignedByteOffset;
            SInt64 seekPacket = floor(newSeekTime / packetDuration);
            err = AudioFileStreamSeek(audioFileStream, seekPacket, &packetAlignedByteOffset, &ioFlags);
            if (!err && !(ioFlags & kAudioFileStreamSeekFlag_OffsetIsEstimated))
            {
                seekTime -= ((seekByteOffset - dataOffset) - packetAlignedByteOffset) * 8.0 / calculatedBitRate;
                seekByteOffset = packetAlignedByteOffset + dataOffset;
            }
        }
    }
    
	//
	// Close the current read straem
	//
	if (stream)
	{
		CFReadStreamClose(stream);
		CFRelease(stream);
		stream = nil;
	}
    
	//
	// Stop the audio queue
	//
    [self togglePause];
	self.state = AS_STOPPING;
	stopReason = AS_STOPPING_TEMPORARILY;
	err = AudioQueueStop(audioQueue, true);
	if (err)
	{
		[self failWithErrorCode:AS_AUDIO_QUEUE_STOP_FAILED];
		return;
	}
    
	//
	// Re-open the file stream. It will request a byte-range starting at
	// seekByteOffset.
	//
	[self openReadStream];
    [self fadein];
}

//
// seekToTime:
//
// Attempts to seek to the new time. Will be ignored if the bitrate or fileLength
// are unknown.
//
// Parameters:
//    newTime - the time to seek to
//
- (void)seekToTime:(double)newSeekTime
{
	@synchronized(self)
	{
		seekWasRequested = YES;
		requestedSeekTime = newSeekTime;
	}
}

//
// progress
//
// returns the current playback progress. Will return zero if sampleRate has
// not yet been detected.
//
- (double)progress
{
	@synchronized(self)
	{
		if (sampleRate > 0 && ![self isFinishing])
		{
            //slide 拖完返回问题
            if (state == AS_WAITING_FOR_DATA || state == AS_WAITING_FOR_QUEUE_TO_START) {
                return -1;
            }
            
			if (state != AS_PLAYING && state != AS_PAUSED && state != AS_BUFFERING)
			{
				return lastProgress;
			}
            
			AudioTimeStamp queueTime;
			Boolean discontinuity;
            
            //切换输出设备会exception
            @try {
                err = AudioQueueGetCurrentTime(audioQueue, NULL, &queueTime, &discontinuity);
            }
            @catch (NSException *exception) {
                DLog(@"%@",exception);
            }
            
			const OSStatus AudioQueueStopped = 0x73746F70; // 0x73746F70 is 'stop'
			if (err == AudioQueueStopped)
			{
				return lastProgress;
			}
			else if (err)
			{
				[self failWithErrorCode:AS_GET_AUDIO_TIME_FAILED];
			}
            
			double progress = seekTime + queueTime.mSampleTime / sampleRate;
			if (progress < 0.0)
			{
				progress = 0.0;
			}
			
			lastProgress = progress;
			return progress;
		}
	}
	
	return lastProgress;
}

//
// calculatedBitRate
//
// returns the bit rate, if known. Uses packet duration times running bits per
//   packet if available, otherwise it returns the nominal bitrate. Will return
//   zero if no useful option available.
//
- (double)calculatedBitRate
{//zzzzzzz
	if (vbr)
	{
		if (packetDuration && processedPacketsCount > BitRateEstimationMinPackets)
		{
			double averagePacketByteSize = processedPacketsSizeTotal / processedPacketsCount;
			return 8.0 * averagePacketByteSize / packetDuration;
		}
        
		if (bitRate)
		{
			return (double)bitRate;
		}
	}
	else
	{
		bitRate = 8.0 * asbd.mSampleRate * asbd.mBytesPerPacket * asbd.mFramesPerPacket;
		return bitRate;
	}
	return 0;
}

//
// duration
//
// Calculates the duration of available audio from the bitRate and fileLength.
//
// returns the calculated duration in seconds.
//
- (double)duration
{
    if (fileTypeHint==kAudioFilePUREType ) {
        return (double)durationMS/1000.0;
    }else{
        double calculatedBitRate = [self calculatedBitRate];
        
        if (calculatedBitRate == 0 || fileLength == 0)
        {
            return 0.0;
        }
        
        return (fileLength - dataOffset) / (calculatedBitRate * 0.125);
    }
}


//
// isMeteringEnabled
//

- (BOOL)isMeteringEnabled {
	UInt32 enabled;
	UInt32 propertySize = sizeof(UInt32);
	OSStatus status = AudioQueueGetProperty(audioQueue, kAudioQueueProperty_EnableLevelMetering, &enabled, &propertySize);
	if(!status) {
		return (enabled == 1);
	}
	return NO;
}


//
// setMeteringEnabled
//

- (void)setMeteringEnabled:(BOOL)enable {
	if(enable == [self isMeteringEnabled])
		return;
	UInt32 enabled = (enable ? 1 : 0);
	OSStatus status = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_EnableLevelMetering, &enabled, sizeof(UInt32));
	// do something if failed?
	if(status)
		return;
}


// level metering
- (float)peakPowerForChannel:(NSUInteger)channelNumber {
	if(![self isMeteringEnabled] || channelNumber >= [self numberOfChannels])
		return 0;
	float peakPower = 0;
	UInt32 propertySize = [self numberOfChannels] * sizeof(AudioQueueLevelMeterState);
	AudioQueueLevelMeterState *audioLevels = calloc(sizeof(AudioQueueLevelMeterState), [self numberOfChannels]);
	OSStatus status = AudioQueueGetProperty(audioQueue, kAudioQueueProperty_CurrentLevelMeter, audioLevels, &propertySize);
	if(!status) {
		peakPower = audioLevels[channelNumber].mPeakPower;
	}
	free(audioLevels);
	return peakPower;
}


- (float)averagePowerForChannel:(NSUInteger)channelNumber {
	if(![self isMeteringEnabled] || channelNumber >= [self numberOfChannels])
		return 0;
	float peakPower = 0;
	UInt32 propertySize = [self numberOfChannels] * sizeof(AudioQueueLevelMeterState);
	AudioQueueLevelMeterState *audioLevels = calloc(sizeof(AudioQueueLevelMeterState), [self numberOfChannels]);
	OSStatus status = AudioQueueGetProperty(audioQueue, kAudioQueueProperty_CurrentLevelMeter, audioLevels, &propertySize);
	if(!status) {
		peakPower = audioLevels[channelNumber].mAveragePower;
	}
	free(audioLevels);
	return peakPower;
}


//
// pause
//
// A togglable pause function.
//
- (void)pause
{
	@synchronized(self)
	{
		if (state == AS_PLAYING)
		{
            [self togglePause];
			err = AudioQueuePause(audioQueue);
			if (err)
			{
				[self failWithErrorCode:AS_AUDIO_QUEUE_PAUSE_FAILED];
				return;
			}
			self.state = AS_PAUSED;
		}
		else if (state == AS_PAUSED)
		{
			err = AudioQueueStart(audioQueue, NULL);
            //zzzzzzzz
            
            
            if (CFReadStreamGetStatus(stream) ==kCFStreamStatusClosed) {
                DLog(@"stream closed,need reconnect");
                reConnect = YES;
            }
            
#if TARGET_OS_IPHONE
			if ([[UIDevice currentDevice] respondsToSelector:@selector(isMultitaskingSupported)]) {
				if (bgTaskId != UIBackgroundTaskInvalid) {
					bgTaskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:NULL];
				}
			}
#endif            
			if (err)
			{
                DLog(@"restart Queue, maybe recreate audioQueue %p",audioQueue);
                
				[self failWithErrorCode:AS_AUDIO_QUEUE_START_FAILED];
				return;
			}
			self.state = AS_PLAYING;
            [self fadein];
		}
	}
}
-(void)togglePause
{
    [self fadeout];
}
- (void)fadeout
{
    if(state != AS_PLAYING) return;
	//float volume = 1.0f;
	int i,repeat=10;

    AudioQueueParameterValue volume =1.0;
    //AudioQueueGetParameter(audioQueue,kAudioQueueParam_Volume ,&volume);
    NSLog(@"volume:%.2f",volume);
	for(i=0;i<repeat;i++) {
		volume -= 1.0f/repeat;
        AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, volume);
		usleep(10000);
	}
    NSLog(@"volume:%.2f",volume);
}
- (void)fadein
{
	if(state != AS_PLAYING ){
        if (state ==AS_WAITING_FOR_QUEUE_TO_START) {
            
        }else {
            return;
        }

    }
	int i,repeat=10;
    AudioQueueParameterValue volume=0.0 ;
    //AudioQueueGetParameter(audioQueue,kAudioQueueParam_Volume ,&volume);
    NSLog(@"volume:%.2f",volume);
	for(i=0;i<repeat;i++) {
		volume += 1.0f/repeat;
        AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, volume);
		//AudioUnitSetParameter(outputUnit, kAudioUnitParameterUnit_LinearGain, kAudioUnitScope_Global, 0, volume, 0);
		usleep(10000);
	}
    NSLog(@"volume:%.2f",volume);
}
//
// stop
//
// This method can be called to stop downloading/playback before it completes.
// It is automatically called when an error occurs.
//
// If playback has not started before this method is called, it will toggle the
// "isPlaying" property so that it is guaranteed to transition to true and
// back to false 
//
- (void)stop
{
	@synchronized(self)
	{
		if (audioQueue &&
			(state == AS_PLAYING || state == AS_PAUSED ||
             state == AS_BUFFERING || state == AS_WAITING_FOR_QUEUE_TO_START ||
             state == AS_WAITING_FOR_DATA || state == AS_STARTING_FILE_THREAD))//zzzz
		{
            [self togglePause];
			self.state = AS_STOPPING;
			stopReason = AS_STOPPING_USER_ACTION;
			err = AudioQueueStop(audioQueue, true);
			if (err)
			{
				[self failWithErrorCode:AS_AUDIO_QUEUE_STOP_FAILED];
				return;
			}
            self.state = AS_STOPPED;//AS_INITIALIZED;
		}
		else if (state != AS_INITIALIZED)
		{
			self.state = AS_STOPPED;
			stopReason = AS_STOPPING_USER_ACTION;
		}
		seekWasRequested = NO;
	}
	//fixme 
    //	while (state != AS_INITIALIZED)
    //	{
    //		[NSThread sleepForTimeInterval:0.1];
    //	}
}

//
// handleReadFromStream:eventType:
//
// Reads data from the network file stream into the AudioFileStream
//
// Parameters:
//    aStream - the network file stream
//    eventType - the event which triggered this method
//
- (void)handleReadFromStream:(CFReadStreamRef)aStream
                   eventType:(CFStreamEventType)eventType
{
	if (aStream != stream)
	{
		// 快速Next strack crash ,we no need fast next track，可以重新的bug
		// Ignore messages from old streams
		// 
		return;
	}

	if (eventType == kCFStreamEventNone) {
        DLog(@"kCFStreamEventNone");
    } else 
        if (eventType == kCFStreamEventErrorOccurred)
        {
            //需要重新连接
            reConnect = YES;
            reconnectTimes++;
            if (reconnectTimes >=3) {
                [self stop];
                stopReason = AS_STOPPING_ERROR;
            }

            DLog(@"网络错误kCFStreamEventErrorOccurred");
//            if (state == AS_PLAYING) {
//                [self pause];
//            }
            //[self failWithErrorCode:AS_AUDIO_DATA_NOT_FOUND];
        } else if(eventType == kCFStreamEventOpenCompleted){
            DLog(@"stream Opened");
        }
        else if (eventType == kCFStreamEventEndEncountered)
        {
            reconnectTimes = 0;
            @synchronized(self)
            {
                if ([self isFinishing])
                {
                    return;
                }
            }
            
            //
            // If there is a partially filled buffer, pass it to the AudioQueue for
            // processing
            //
            if (bytesFilled)
            {
                if (self.state == AS_WAITING_FOR_DATA)
                {
                    //
                    // Force audio data smaller than one whole buffer to play.
                    //
                    self.state = AS_FLUSHING_EOF;
                }
                [self enqueueBuffer];
            }
            
            @synchronized(self)
            {
                if (state == AS_WAITING_FOR_DATA)
                {
                    //[self failWithErrorCode:AS_AUDIO_DATA_NOT_FOUND];
                    DLog(@"AS_WAITING_FOR_DATA,no data receive, so next song,%d",__LINE__);
                    //reConnect = YES;// 重现连接会 Audio queue start failed.;
                    //bug bug...
                    //fixme allways spining Button;
                    errorCode = AS_AUDIO_DATA_NOT_FOUND; 
                    self.state = AS_STOPPED;
                    stopReason = AS_STOPPING_ERROR;
                    return;
                }
                
                //
                // We left the synchronized section to enqueue the buffer so we
                // must check that we are !finished again before touching the
                // audioQueue
                //
                else if (![self isFinishing])
                {
                    if (audioQueue)
                    {
                        //
                        // Set the progress at the end of the stream
                        //
                        err = AudioQueueFlush(audioQueue);
                        if (err)
                        {
                            [self failWithErrorCode:AS_AUDIO_QUEUE_FLUSH_FAILED];
                            return;
                        }
                        
                        self.state = AS_STOPPING;
                        stopReason = AS_STOPPING_EOF;
                        err = AudioQueueStop(audioQueue, false);
                        if (err)
                        {
                            [self failWithErrorCode:AS_AUDIO_QUEUE_FLUSH_FAILED];
                            return;
                        }
                    }
                    else
                    {
                        self.state = AS_STOPPED;
                        stopReason = AS_STOPPING_EOF;
                    }
                }
            }
        }
        else if (eventType == kCFStreamEventHasBytesAvailable)
        {
            lastRecivedTime=[NSDate date];
            if (!httpHeaders && isfile == NO)
            {
                CFTypeRef message =
				CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
                httpHeaders =
				(__bridge_transfer NSDictionary *)CFHTTPMessageCopyAllHeaderFields((CFHTTPMessageRef)message);
                CFRelease(message);
                
                //
                // Only read the content length if we seeked to time zero, otherwise
                // we only have a subset of the total bytes.
                //
                if (seekByteOffset == 0)
                {
                    fileLength = [[httpHeaders objectForKey:@"Content-Length"] integerValue];
                }
            }
            
            if (!audioFileStream )
            {
                //
                // Attempt to guess the file type from the httpHeaders MIME type value.
                //
                // If you have a fixed file-type, you may want to hardcode this.
                //
                fileTypeHint =
                [AudioStreamer hintForMIMEType:[httpHeaders objectForKey:@"Content-Type"]];
                
                if (fileTypeHint == kAudioFilePUREType) {
                    if (!pCODEC) {
                        @synchronized(self){
                            if ([self LoadHeader])//LoadHeader(stream,&pure_header, &frame_bytes,&durationMS)
                            {
                                seekByteOffset += sizeof(pure_header);
                                pCODEC = Pure_CreateDecoder(& pure_header); 
                                if (!pCODEC)
                                {
                                    DLog(@"pCODEC init error,%d",__LINE__);
                                    [self failWithErrorCode:AS_AUDIO_DATA_NOT_FOUND];
                                    return;
                                }else{
                                    //create asbd;
                                    [self handlePropertyChangeForPur];
                                }
                            }
                        }
                        
                    }
                    
                }//end pur
                
                // create an audio file stream parser
                if (fileTypeHint != kAudioFilePUREType) {
                    err = AudioFileStreamOpen((__bridge void *)(self), MyPropertyListenerProc, MyPacketsProc, 
                                              fileTypeHint, &audioFileStream);
                    if (err)
                    {
                        [self failWithErrorCode:AS_FILE_STREAM_OPEN_FAILED];
                        return;
                    } 
                }
            }
            
            
            UInt8 bytes[kAQDefaultBufSize];
            UInt32 length = 0;		
            @synchronized(self)
            {
                if ([self isFinishing] || !CFReadStreamHasBytesAvailable(stream))
                {
                    return;
                }
                
                //
                // Read the bytes from the stream
                //
                if (fileTypeHint == kAudioFilePUREType && pCODEC) {
                    length = CFReadStreamRead(stream, bytes,kAQDefaultBufSize);//
                    //kAQDefaultBufSize 为多少？
                    if (length == -1)
                    {
                        //[self failWithErrorCode:AS_AUDIO_DATA_NOT_FOUND];
                        //读取error,reconnect 
                        return;
                    }
                    
                    if (length == 0)
                    {
                        return;
                    }
                    seekByteOffset += length;
                }else{
                    length = CFReadStreamRead(stream, bytes, kAQDefaultBufSize);
                    
                    if (length == -1)
                    {
                        [self failWithErrorCode:AS_AUDIO_DATA_NOT_FOUND];
                        return;
                    }
                    
                    if (length == 0)
                    {
                        return;
                    } 
                }
            }
            
            if (discontinuous)
            {//进入这里
                if (fileTypeHint != kAudioFilePUREType) {
                    err = AudioFileStreamParseBytes(audioFileStream, length, bytes, kAudioFileStreamParseFlag_Discontinuity);
                    if (err)
                    {
                        [self failWithErrorCode:AS_FILE_STREAM_PARSE_BYTES_FAILED];
                        return;
                    } 
                }else{
                    //处理pur stream
                    //NSLog(@"readstream +++%ld,%s",length,_cmd);
                    [self handleAudioPackets:bytes numberBytes:length numberPackets:(length/frame_bytes) packetDescriptions:nil];
                }
                
            }
            else
            {
                if (fileTypeHint != kAudioFilePUREType) {
                    err = AudioFileStreamParseBytes(audioFileStream, length, bytes, 0);
                    if (err)
                    {
                        [self failWithErrorCode:AS_FILE_STREAM_PARSE_BYTES_FAILED];
                        return;
                    }
                }else{
                    //处理pur stream
                    //NSLog(@"readstream +++ 000 %ld %s",length,_cmd);
                    [self handleAudioPackets:bytes numberBytes:length numberPackets:(length/frame_bytes) packetDescriptions:nil];//小于一个包,crash
                }
                
            }
            //#endif
        }
}

//
// enqueueBuffer
//
// Called from MyPacketsProc and connectionDidFinishLoading to pass filled audio
// bufffers (filled by MyPacketsProc) to the AudioQueue for playback. This
// function does not return until a buffer is idle for further filling or
// the AudioQueue is stopped.
//
// This function is adapted from Apple's example in AudioFileStreamExample with
// CBR functionality added.
//

- (void)enqueueBuffer
{
	@synchronized(self)
	{
		if ([self isFinishing] || stream == 0)
		{
			return;
		}
		
		inuse[fillBufferIndex] = true;		// set in use flag
		buffersUsed++;
        
		// enqueue buffer
		AudioQueueBufferRef fillBuf = audioQueueBuffer[fillBufferIndex];
       
        if (fileTypeHint == kAudioFilePUREType) {
                        
            fillBuf->mAudioDataByteSize = 1920*2;
            err = AudioQueueEnqueueBuffer(audioQueue, fillBuf, 0, NULL);
            
        }else{
            fillBuf->mAudioDataByteSize = bytesFilled;
            if (packetsFilled)
            {
                err = AudioQueueEnqueueBuffer(audioQueue, fillBuf, packetsFilled, packetDescs);
            }
            else
            {
                err = AudioQueueEnqueueBuffer(audioQueue, fillBuf, 0, NULL);
            }
        }
		
		
		if (err)
		{
			[self failWithErrorCode:AS_AUDIO_QUEUE_ENQUEUE_FAILED];
			return;
		}
        
		
		if (state == AS_BUFFERING ||
			state == AS_WAITING_FOR_DATA ||
			state == AS_FLUSHING_EOF ||
			(state == AS_STOPPED && stopReason == AS_STOPPING_TEMPORARILY))
		{
			//
			// Fill all the buffers before starting. This ensures that the
			// AudioFileStream stays a small amount ahead of the AudioQueue to
			// avoid an audio glitch playing streaming files on iPhone SDKs < 3.0
			//
            if (stopReason == AS_STOPPING_TEMPORARILY) {
                //DLog(@"AS_STOPPING_TEMPORARILY");
            }
			if (state == AS_FLUSHING_EOF || buffersUsed == kNumAQBufs - 1)
			{
				if (self.state == AS_BUFFERING)
				{
					err = AudioQueueStart(audioQueue, NULL);
#if TARGET_OS_IPHONE                    
					if ([[UIDevice currentDevice] respondsToSelector:@selector(isMultitaskingSupported)]) {
						bgTaskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:NULL];
					}
#endif					
					if (err)
					{
						[self failWithErrorCode:AS_AUDIO_QUEUE_START_FAILED];
						return;
					}
					self.state = AS_PLAYING;
                    
				}
				else
				{
					self.state = AS_WAITING_FOR_QUEUE_TO_START;
                    
					err = AudioQueueStart(audioQueue, NULL);
                    [self fadein];
#if TARGET_OS_IPHONE 
					if ([[UIDevice currentDevice] respondsToSelector:@selector(isMultitaskingSupported)]) {
						bgTaskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:NULL];
					}
#endif					
					if (err)
					{
						[self failWithErrorCode:AS_AUDIO_QUEUE_START_FAILED];
						return;
					}
				}
			}
		}
        
		// go to next buffer
		if (++fillBufferIndex >= kNumAQBufs) fillBufferIndex = 0;
        
		bytesFilled = 0;		// reset bytes filled
		packetsFilled = 0;		// reset packets filled
	}
    
	// wait until next buffer is not in use
	pthread_mutex_lock(&queueBuffersMutex); 
	while (inuse[fillBufferIndex])
	{
		pthread_cond_wait(&queueBufferReadyCondition, &queueBuffersMutex);
	}
	pthread_mutex_unlock(&queueBuffersMutex);
}

//
// createQueue
//
// Method to create the AudioQueue from the parameters gathered by the
// AudioFileStream.
//
// Creation is deferred to the handling of the first audio packet (although
// it could be handled any time after kAudioFileStreamProperty_ReadyToProducePackets
// is true).
//
- (void)createQueue
{
	sampleRate = asbd.mSampleRate;
    if (fileTypeHint == kAudioFilePUREType){
        packetDuration = durationMS/1000.0;
    }else{
        packetDuration = asbd.mFramesPerPacket / sampleRate;
    }
	
	//vol
	numberOfChannels = asbd.mChannelsPerFrame;
	
	// create the audio queue
	err = AudioQueueNewOutput(&asbd, MyAudioQueueOutputCallback, (__bridge void *)(self), NULL, NULL, 0, &audioQueue);
	if (err)
	{
		[self failWithErrorCode:AS_AUDIO_QUEUE_CREATION_FAILED];
		return;
	}
	
	// start the queue if it has not been started already
	// listen to the "isRunning" property
	err = AudioQueueAddPropertyListener(audioQueue, kAudioQueueProperty_IsRunning, MyAudioQueueIsRunningCallback, (__bridge void *)(self));
	if (err)
	{
		[self failWithErrorCode:AS_AUDIO_QUEUE_ADD_LISTENER_FAILED];
		return;
	}
	
	// get the packet size if it is available
	if (vbr && (fileTypeHint != kAudioFilePUREType))
	{
		UInt32 sizeOfUInt32 = sizeof(UInt32);
		err = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_PacketSizeUpperBound, &sizeOfUInt32, &packetBufferSize);
		if (err || packetBufferSize == 0)
		{
            // No packet size available, just use the default
            packetBufferSize = kAQDefaultBufSize;
            
		}
	}else if(fileTypeHint == kAudioFilePUREType){
        packetBufferSize = 1920*2;//固定
        // allocate audio queue buffers
        for (unsigned int i = 0; i < kNumAQBufs; ++i)
        {
            err = AudioQueueAllocateBuffer(audioQueue, packetBufferSize, &audioQueueBuffer[i]);
            if (err)
            {
                [self failWithErrorCode:AS_AUDIO_QUEUE_BUFFER_ALLOCATION_FAILED];
                return;
            }
        }
    }else
	{
		packetBufferSize = kAQDefaultBufSize;
	}
    
    if (fileTypeHint != kAudioFilePUREType) {
        // allocate audio queue buffers
        for (unsigned int i = 0; i < kNumAQBufs; ++i)
        {
            err = AudioQueueAllocateBuffer(audioQueue, packetBufferSize, &audioQueueBuffer[i]);
            if (err)
            {
                [self failWithErrorCode:AS_AUDIO_QUEUE_BUFFER_ALLOCATION_FAILED];
                return;
            }
        }
        
        // get the cookie size
        UInt32 cookieSize;
        Boolean writable;
        OSStatus ignorableError;
        ignorableError = AudioFileStreamGetPropertyInfo(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable);
        if (ignorableError)
        {
            return;
        }
        
        // get the cookie data
        void* cookieData = calloc(1, cookieSize);
        ignorableError = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData);
        if (ignorableError)
        {
            return;
        }
        
        // set the cookie on the queue.
        ignorableError = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_MagicCookie, cookieData, cookieSize);
        free(cookieData);
        if (ignorableError)
        {
            return;
        }
    }
}

//
// handlePropertyChangeForFileStream:fileStreamPropertyID:ioFlags:
//
// Object method which handles implementation of MyPropertyListenerProc
//
// Parameters:
//    inAudioFileStream - should be the same as self->audioFileStream
//    inPropertyID - the property that changed
//    ioFlags - the ioFlags passed in
//
#pragma create absd

- (void)handlePropertyChangeForPur
{
    @synchronized(self){
        if ([self isFinishing])
		{
			return;
		}
        discontinuous = true;
        
        asbd.mSampleRate = 48000;//固定码率 SAMPLE_RATE;
        asbd.mFormatID = kAudioFormatLinearPCM;
        asbd.mFormatFlags =  kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        asbd.mBytesPerPacket = 4;//1920*2;
        asbd.mFramesPerPacket = 1;//1920/2;
        asbd.mBytesPerFrame = 4;
        asbd.mChannelsPerFrame = 2;
        asbd.mBitsPerChannel = 16;
        //        agc.FrameCount =  FRAME_COUNT;
        //        agc.sampleLen = pure_header.m_dwBLOCKS;//len/BYTES_PER_SAMPLE;
        //        agc.playPtr = 0;
        //        agc.player = obj;
        //        //agc.pcmBuffer = pcmBuffer;
        //        agc.fp = fp;
        //        agc.pCODEC=pCODEC;
    }
}

- (void)handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream
                     fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID
                                  ioFlags:(UInt32 *)ioFlags
{
	@synchronized(self)
	{
		if ([self isFinishing])
		{
			return;
		}
		
		if (inPropertyID == kAudioFileStreamProperty_ReadyToProducePackets)
		{
			discontinuous = true;
		}
		else if (inPropertyID == kAudioFileStreamProperty_DataOffset)
		{
			SInt64 offset;
			UInt32 offsetSize = sizeof(offset);
			err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataOffset, &offsetSize, &offset);
			if (err)
			{
				[self failWithErrorCode:AS_FILE_STREAM_GET_PROPERTY_FAILED];
				return;
			}
			dataOffset = offset;
			
			if (audioDataByteCount)
			{
				fileLength = dataOffset + audioDataByteCount;
			}
		}
		else if (inPropertyID == kAudioFileStreamProperty_AudioDataByteCount)
		{
			UInt32 byteCountSize = sizeof(UInt64);
			err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_AudioDataByteCount, &byteCountSize, &audioDataByteCount);
			if (err)
			{
				[self failWithErrorCode:AS_FILE_STREAM_GET_PROPERTY_FAILED];
				return;
			}
			fileLength = dataOffset + audioDataByteCount;
		}
		else if (inPropertyID == kAudioFileStreamProperty_DataFormat)
		{
			if (asbd.mSampleRate == 0)
			{
				UInt32 asbdSize = sizeof(asbd);
				
				// get the stream format.
				err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &asbdSize, &asbd);
				if (err)
				{
					[self failWithErrorCode:AS_FILE_STREAM_GET_PROPERTY_FAILED];
					return;
				}
			}
		}
		else if (inPropertyID == kAudioFileStreamProperty_FormatList)
		{
			Boolean outWriteable;
			UInt32 formatListSize;
			err = AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, &outWriteable);
			if (err)
			{
				[self failWithErrorCode:AS_FILE_STREAM_GET_PROPERTY_FAILED];
				return;
			}
			
			AudioFormatListItem *formatList = malloc(formatListSize);
	        err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, formatList);
			if (err)
			{
				[self failWithErrorCode:AS_FILE_STREAM_GET_PROPERTY_FAILED];
				return;
			}
            
			for (int i = 0; i * sizeof(AudioFormatListItem) < formatListSize; i += sizeof(AudioFormatListItem))
			{
				AudioStreamBasicDescription pasbd = formatList[i].mASBD;
                
				if (pasbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2 && 
                    //#if TARGET_OS_IPHONE			
                    //				   [[UIDevice currentDevice] platformHasCapability:(UIDeviceSupportsARMV7)] && 
                    //#endif
                    kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_MIN)
				{
					// We found HE-AAC v2 (SBR+PS), but before trying to play it
					// we need to make sure that both the hardware and software are
					// capable of doing so...
					DLog(@"HE-AACv2 found!");
#if !TARGET_IPHONE_SIMULATOR
					asbd = pasbd;
#endif
					break;
				} else
                    if (pasbd.mFormatID == kAudioFormatMPEG4AAC_HE)
                    {
                        //
                        // We've found HE-AAC, remember this to tell the audio queue
                        // when we construct it.
                        //
#if !TARGET_IPHONE_SIMULATOR
                        asbd = pasbd;
#endif
                        break;
                    }                                
			}
			free(formatList);
		}
		else
		{
            //			NSLog(@"Property is %c%c%c%c",
            //				((char *)&inPropertyID)[3],
            //				((char *)&inPropertyID)[2],
            //				((char *)&inPropertyID)[1],
            //				((char *)&inPropertyID)[0]);
		}
	}
}

//
// handleAudioPackets:numberBytes:numberPackets:packetDescriptions:
//
// Object method which handles the implementation of MyPacketsProc
//
// Parameters:
//    inInputData - the packet data
//    inNumberBytes - byte size of the data
//    inNumberPackets - number of packets in the data
//    inPacketDescriptions - packet descriptions
//
- (void)handleAudioPackets:(const void *)inInputData
               numberBytes:(UInt32 )inNumberBytes//UInt32
             numberPackets:(UInt32)inNumberPackets
        packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions;
{
    
	@synchronized(self)
	{
		if ([self isFinishing])
		{
			return;
		}
		
		if (bitRate == 0)
		{
			//
			// m4a and a few other formats refuse to parse the bitrate so
			// we need to set an "unparseable" condition here. If you know
			// the bitrate (parsed it another way) you can set it on the
			// class if needed.
			//
			bitRate = ~0;
		}
		
		// we have successfully read the first packests from the audio stream, so
		// clear the "discontinuous" flag
		if (discontinuous)
		{
			discontinuous = false;
		}
		
		if (!audioQueue)
		{
            if (fileTypeHint == kAudioFilePUREType)
            {
                [self createQueue];   
            } else {
                vbr = (inPacketDescriptions != nil);
                [self createQueue];
            }
			
		}
	}
    
    
	// the following code assumes we're streaming VBR data. for CBR data, the second branch is used.
	if (inPacketDescriptions)
	{
		for (int i = 0; i < inNumberPackets; ++i)
		{
			SInt64 packetOffset = inPacketDescriptions[i].mStartOffset;
			SInt64 packetSize   = inPacketDescriptions[i].mDataByteSize;
			size_t bufSpaceRemaining;
			
			if (processedPacketsCount < BitRateEstimationMaxPackets)
			{
				processedPacketsSizeTotal += packetSize;
				processedPacketsCount += 1;
			}
			
			@synchronized(self)
			{
				// If the audio was terminated before this point, then
				// exit.
				if ([self isFinishing])
				{
					return;
				}
				
				if (packetSize > packetBufferSize)
				{
					[self failWithErrorCode:AS_AUDIO_BUFFER_TOO_SMALL];
				}
                
				bufSpaceRemaining = packetBufferSize - bytesFilled;
			}
            
			// if the space remaining in the buffer is not enough for this packet, then enqueue the buffer.
			if (bufSpaceRemaining < packetSize)
			{
				[self enqueueBuffer];
			}
			
			@synchronized(self)
			{
				// If the audio was terminated while waiting for a buffer, then
				// exit.
				if ([self isFinishing])
				{
					return;
				}
				
				//
				// If there was some kind of issue with enqueueBuffer and we didn't
				// make space for the new audio data then back out
				//
                //http://github.com/mattgallagher/AudioStreamer/issues/#issue/22
				if (bytesFilled + packetSize > packetBufferSize)
				{
					return;
				}
				
				// copy data to the audio queue buffer
				AudioQueueBufferRef fillBuf = audioQueueBuffer[fillBufferIndex];
				memcpy((char*)fillBuf->mAudioData + bytesFilled, (const char*)inInputData + packetOffset, packetSize);
                
				// fill out packet description
				packetDescs[packetsFilled] = inPacketDescriptions[i];
				packetDescs[packetsFilled].mStartOffset = bytesFilled;
				// keep track of bytes filled and packets filled
				bytesFilled += packetSize;
				packetsFilled += 1;
			}
			
			// if that was the last free packet description, then enqueue the buffer.
			size_t packetsDescsRemaining = kAQMaxPacketDescs - packetsFilled;
			if (packetsDescsRemaining == 0) {
				[self enqueueBuffer];
			}
		}	
	}
	else
	{
        size_t offset = 0;
        size_t inBytes=inNumberBytes;
        while (inNumberBytes)
        {//fixme
            // if the space remaining in the buffer is not enough for this packet, then enqueue the buffer.
            //对于pur bytesFilled 为上一个frame 填充的数据，但是frame 还没满
            
            size_t bufSpaceRemaining;
            if (fileTypeHint != kAudioFilePUREType) {
                bufSpaceRemaining  = kAQDefaultBufSize - bytesFilled;
                if (bufSpaceRemaining < inNumberBytes)
                {  
                    [self enqueueBuffer];
                }
            }
            
            @synchronized(self)
            {
                // If the audio was terminated while waiting for a buffer, then
                // exit.
                if ([self isFinishing])
                {
                    return;
                }
                
                size_t copySize;
                if (fileTypeHint != kAudioFilePUREType) {
                    bufSpaceRemaining  = kAQDefaultBufSize - bytesFilled;
                    if (bufSpaceRemaining < inNumberBytes)
                    {
                        copySize = bufSpaceRemaining;
                    }
                    else
                    {
                        copySize = inNumberBytes;
                    }
                    //
                    // If there was some kind of issue with enqueueBuffer and we didn't
                    // make space for the new audio data then back out
                    //
                    if (bytesFilled >= packetBufferSize)
                    {
                        return;
                    }
                }
                
                // copy data to the audio queue buffer
                AudioQueueBufferRef fillBuf = audioQueueBuffer[fillBufferIndex];
                
                if (fileTypeHint != kAudioFilePUREType){
                    
                    memcpy((char*)fillBuf->mAudioData + bytesFilled, (const char*)(inInputData + offset), copySize);
                    bytesFilled += copySize;
                }else{
                    //fixme
                    short *coreAudiobuffer;
                    //pur
                    bufSpaceRemaining  = frame_bytes - bytesFilled;
                    coreAudiobuffer =  (short*)fillBuf->mAudioData;
                    if (bufSpaceRemaining <=inNumberBytes) {
                        copySize = bufSpaceRemaining;//满
                        if (bytesFilled ==0) {
                            Pure_DecodeFrame(pCODEC, (BYTE*)(inInputData+offset), coreAudiobuffer);
                        }else{
                            
                            memcpy((frame_buffer+bytesFilled), (const char*)(inInputData+offset), copySize);
                            Pure_DecodeFrame(pCODEC, frame_buffer, coreAudiobuffer);
                        }
                        
                    }else {
                        copySize = inNumberBytes;//不满
                        if (bytesFilled ==0) {
                            memset(frame_buffer, 0,sizeof(frame_buffer));
                        }
                        memcpy((frame_buffer+bytesFilled), (const char*)(inInputData+offset), copySize);
                        bytesFilled += copySize;
                        
                        break;
                    }
                }

                // keep track of bytes filled and packets filled                
                packetsFilled += 1;
                inNumberBytes -= copySize;
                offset += copySize;
            } //EXC_BAD_ACCESS
            [self enqueueBuffer];//zzzzzzzzzzzzz
            
        } 
	}
}

//
// handleBufferCompleteForQueue:buffer:
//
// Handles the buffer completetion notification from the audio queue
//
// Parameters:
//    inAQ - the queue
//    inBuffer - the buffer
//
- (void)handleBufferCompleteForQueue:(AudioQueueRef)inAQ
                              buffer:(AudioQueueBufferRef)inBuffer
{
	unsigned int bufIndex = -1;
	for (unsigned int i = 0; i < kNumAQBufs; ++i)
	{
		if (inBuffer == audioQueueBuffer[i])
		{
			bufIndex = i;
			break;
		}
	}
    
	if (bufIndex == -1)
	{
		[self failWithErrorCode:AS_AUDIO_QUEUE_BUFFER_MISMATCH];
		pthread_mutex_lock(&queueBuffersMutex);
		pthread_cond_signal(&queueBufferReadyCondition);
		pthread_mutex_unlock(&queueBuffersMutex);
		return;
	}
	
	// signal waiting thread that the buffer is free.
	pthread_mutex_lock(&queueBuffersMutex);
	inuse[bufIndex] = false;
	buffersUsed--;
    
    //
    //  Enable this logging to measure how many buffers are queued at any time.
    //
#if LOG_QUEUED_BUFFERS
	DLog(@"Queued buffers: %ld", buffersUsed);
#endif
	

    
    
	pthread_cond_signal(&queueBufferReadyCondition);
	pthread_mutex_unlock(&queueBuffersMutex);
}

//
// handlePropertyChangeForQueue:propertyID:
//
// Implementation for MyAudioQueueIsRunningCallback
//
// Parameters:
//    inAQ - the audio queue
//    inID - the property ID
//
- (void)handlePropertyChangeForQueue:(AudioQueueRef)inAQ
                          propertyID:(AudioQueuePropertyID)inID
{
    @autoreleasepool {
		@synchronized(self)
		{
			if (inID == kAudioQueueProperty_IsRunning)
			{
				if (state == AS_STOPPING || state == AS_STOPPED)
				{
					self.state = AS_STOPPED;
				}
				else if (state == AS_WAITING_FOR_QUEUE_TO_START)
				{
					//
					// Note about this bug avoidance quirk:
					//
					// On cleanup of the AudioQueue thread, on rare occasions, there would
					// be a crash in CFSetContainsValue as a CFRunLoopObserver was getting
					// removed from the CFRunLoop.
					//
					// After lots of testing, it appeared that the audio thread was
					// attempting to remove CFRunLoop observers from the CFRunLoop after the
					// thread had already deallocated the run loop.
					//
					// By creating an NSRunLoop for the AudioQueue thread, it changes the
					// thread destruction order and seems to avoid this crash bug -- or
					// at least I haven't had it since (nasty hard to reproduce error!)
					//              
					
					[NSRunLoop currentRunLoop];
                    
					self.state = AS_PLAYING;
                    //[self fadein];
#if TARGET_OS_IPHONE				
					if ([[UIDevice currentDevice] respondsToSelector:@selector(isMultitaskingSupported)]) {
						if (bgTaskId != UIBackgroundTaskInvalid) {
							[[UIApplication sharedApplication] endBackgroundTask: bgTaskId];
						}
						
						bgTaskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:NULL];
					}
#endif                
                    
                }
                else if(self.state == AS_WAITING_FOR_DATA)
                {
                    DLog(@"AS_WAITING_FOR_DATA.");
                }else {
                    DLog(@"AudioQueue changed state in unexpected way.");
                }
            }
            
        }
    }
}

#if TARGET_OS_IPHONE
//
// handleInterruptionChangeForQueue:propertyID:
//
// Implementation for MyAudioQueueInterruptionListener
//
// Parameters:
//    inAQ - the audio queue
//    inID - the property ID
//
- (void)handleInterruptionChangeToState:(AudioQueuePropertyID)inInterruptionState 
{
	if (inInterruptionState == kAudioSessionBeginInterruption)
	{ 
		if ([self isPlaying]) {
			[self pause];
			
			pausedByInterruption = YES; 
		} 
	}
	else if (inInterruptionState == kAudioSessionEndInterruption) 
	{
		AudioSessionSetActive( true );
		
		if ([self isPaused] && pausedByInterruption) {
			[self pause]; // this is actually resume
			
			pausedByInterruption = NO; // this is redundant 
		}
	}
}
#endif

@end


