//
//  AudioFiler.m
//  MacStreamingPlayer
//
//  Created by XiangBo Kong on 11-12-1.
//  Copyright (c) 2011年 __MyCompanyName__. All rights reserved.
//

#import "AudioFiler.h"

@interface AudioFiler (private) 
- (void)handleReadFromStream:(CFReadStreamRef)aStream
                   eventType:(CFStreamEventType)eventType;
- (void)handleAudioPackets:(const void *)inInputData
               numberBytes:(UInt32 )inNumberBytes//UInt32
             numberPackets:(UInt32)inNumberPackets
        packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions;
@end

void AFReadStreamCallBack
(
 CFReadStreamRef aStream,
 CFStreamEventType eventType,
 void* inClientInfo
 );
void AFReadStreamCallBack
(
 CFReadStreamRef aStream,
 CFStreamEventType eventType,
 void* inClientInfo
 )
{
	AudioFiler* streamer = (__bridge AudioFiler *)inClientInfo;
	[streamer handleReadFromStream:aStream eventType:eventType];
}

@implementation AudioFiler

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
    }else if (eventType == kCFStreamEventErrorOccurred)
	{
        //需要重新连接
        //reConnect = YES;
        DLog(@"kCFStreamEventErrorOccurred");
		//[self failWithErrorCode:AS_AUDIO_DATA_NOT_FOUND];
	}else if(eventType == kCFStreamEventOpenCompleted){
        DLog(@"stream Opened");
    }
	else if (eventType == kCFStreamEventEndEncountered)
	{
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
                DLog(@"AS_WAITING_FOR_DATA,%d",__LINE__);
                //reConnect = YES;// 重现连接会 Audio queue start failed.;
                //bug bug...
                //fixme allways spining Button;
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
		
        
		UInt8 bytes[kAQDefaultBufSize];
		UInt32 length = 0;//CFIndex    
		
		@synchronized(self)
		{
			if ([self isFinishing] || !CFReadStreamHasBytesAvailable(stream))
			{
				return;
			}
			
			//
			// Read the bytes from the stream
			//
            if (fileTypeHint == kAudioFilePUREType) {
                //fixme
                if (pCODEC) {
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
                }
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

	}
}


- (BOOL)openReadStream
{
    stream = CFReadStreamCreateWithFile(kCFAllocatorDefault,(__bridge CFURLRef)url);
    fileTypeHint = kAudioFilePUREType;
    self.state = AS_WAITING_FOR_DATA;//这里有问题
    
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
    @synchronized(self){
        if ([self LoadHeader])//LoadHeader(stream,&pure_header, &frame_bytes,&durationMS)
        {
            seekByteOffset += sizeof(pure_header);
            pCODEC = Pure_CreateDecoder(& pure_header); 
            if (!pCODEC)
            {
                DLog(@"pCODEC init error,%d",__LINE__);
                [self failWithErrorCode:AS_AUDIO_DATA_NOT_FOUND];
                return NO;
            }else{
                //create asbd;
                //设置参数
                [self handlePropertyChangeForPur];
                [self createQueue];
            }
        }else{
            return NO;//头解析出错
        }
    }
    //
    // Set our callback function to receive the data
    // 对与文件读写RunLoop 貌似不可以
    CFStreamClientContext context = {0, (__bridge void *)(self), NULL, NULL, NULL};
    CFReadStreamSetClient(
                          stream,
                          kCFStreamEventNone|kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered|kCFStreamEventOpenCompleted,
                          AFReadStreamCallBack,
                          &context);
    CFReadStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    
    return  YES;
}

- (void)handleAudioPackets:(const void *)inInputData
               numberBytes:(UInt32 )inNumberBytes//UInt32
             numberPackets:(UInt32)inNumberPackets
        packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions
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
            {//fixme to here
                [self createQueue];   
            }else{
                vbr = (inPacketDescriptions != nil);
                [self createQueue];
            }
			
		}
	}
    
    
	// the following code assumes we're streaming VBR data. for CBR data, the second branch is used.
	if (inPacketDescriptions)
	{
        DLog(@"not go here");
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
            }//else{
            //pur 
            //bufSpaceRemaining  = frame_bytes - bytesFilled;
            //[self enqueueBuffer];
            //}
            
            
            
            @synchronized(self)
            {
                // If the audio was terminated while waiting for a buffer, then
                // exit.
                if ([self isFinishing])
                {
                    return;
                }
                
                //bufSpaceRemaining = kAQDefaultBufSize - bytesFilled;
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
                }else{
                    //pur
                    bufSpaceRemaining  = frame_bytes - bytesFilled;
                    copySize = bufSpaceRemaining;
                }
                
                // copy data to the audio queue buffer
                AudioQueueBufferRef fillBuf = audioQueueBuffer[fillBufferIndex];
                //NSLog(@"enqueue index:%d",fillBufferIndex);
                if (fileTypeHint != kAudioFilePUREType){
                    
                    memcpy((char*)fillBuf->mAudioData + bytesFilled, (const char*)(inInputData + offset), copySize);
                }else{
                    //fixme
                    short *coreAudiobuffer;
                    coreAudiobuffer =  (short*)fillBuf->mAudioData;
                    if (bytesFilled >0) {
                        
                        if( memcpy((frame_buffer+bytesFilled), (const char*)(inInputData), bufSpaceRemaining)){
                            if (Pure_DecodeFrame(pCODEC, frame_buffer, coreAudiobuffer)){

                                
                            }else{
                                DLog(@"decode  error"); 
                            }
                            
                        }
                    }else{
                        if (inNumberBytes < frame_bytes && inNumberBytes != 0) {
                            memset(frame_buffer, 0, sizeof(frame_buffer));
                            memcpy(frame_buffer, (const char*)(inInputData+offset), inNumberBytes);
                            bytesFilled = inNumberBytes;
                            //NSLog(@"222 %d,frame_bytes %ld,offset %d bytesFilled %d,",copySize,frame_bytes,offset,bytesFilled);
                            return;
                        }else{
                           
                            if (offset >=inBytes) {
                                //reConnect = YES;
                                DLog(@"error found,now next track,丢包，跳数据 fixme");
                                [self pause];
                                self.state = AS_INITIALIZED;
                                return;
                            }
                            NSAssert(offset < kAQDefaultBufSize,@"offset error ");
                            //NSAssert(offset < inNumberBytes,@"offset error ");
                            if (Pure_DecodeFrame(pCODEC, (BYTE*)(inInputData+offset), coreAudiobuffer))
                            { //fread(& frame_buffer, 1, , fp)
                                //length 传过来120,offset 11240肯定不对吗
                                //inNumberBytes 4294956176 
                                //(short*) outQB->mAudioData;
                                
                                //return 1;
                                //
                                //[self enqueueBuffer];
                                copySize = frame_bytes;
                                //NSLog(@"333 copySize %d,frame_bytes %d,offset %ld bytesFilled %d",copySize,frame_bytes,offset,bytesFilled);
                                //
                            }else{
                                
                                DLog(@"decode error -%lu,%ld,%s",copySize,frame_bytes,sel_getName(_cmd));
                                [self failWithErrorCode:AS_FILE_STREAM_GET_PROPERTY_FAILED];
                                //return;
                            } 
                        }
                        
                    }
                    
                }
                
                
                
                // keep track of bytes filled and packets filled
                if (fileTypeHint != kAudioFilePUREType) {
                    bytesFilled += copySize;
                }
                
                packetsFilled += 1;
                inNumberBytes -= copySize;
                offset += copySize;
            } //EXC_BAD_ACCESS
            [self enqueueBuffer];
            
        }
        
        
	}
}

- (void)internalSeekToTime:(double)newSeekTime
{
    if ([self calculatedBitRate] == 0.0 )//|| fileLength <= 0
	{
		return;
	}
	//需要算range
    if (fileTypeHint==kAudioFilePUREType ) {

        long frameCount= (long)newSeekTime*1000/20;

        seekByteOffset = (CFIndex)sizeof(pure_header)+frameCount*324;
        DLog(@"%ld seaktime:%f",(long)seekByteOffset,newSeekTime);
        bytesFilled = 0;
        memset(frame_buffer, 0, sizeof(frame_buffer));
        //Pure_SeekReset(pCODEC);
        
        
        seekTime = newSeekTime;
    }     
	//
	// Stop the audio queue
	//
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
	//[self openReadStream];//不支持
    //seekByteOffset
    CFReadStreamSetProperty(stream,kCFStreamPropertyFileCurrentOffset,(__bridge CFNumberRef)[NSNumber numberWithInt:seekByteOffset]);
}
@end
