//
//  StreamMuxer.hpp
//
//  Created by xqk on 2017/4/28.
//  Copyright  2017年 xhan. All rights reserved.
//

#ifndef StreamMuxer_hpp
#define StreamMuxer_hpp

#include <pthread.h>
#include <memory.h>
#include <string.h>
#include "KxLogger.h"

#ifdef __cplusplus
extern "C"
{
#endif

#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavutil/mathematics.h>
#include <libavutil/time.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>


#include <libavutil/avassert.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libavutil/mathematics.h>
#include "libavcodec/avcodec.h"
//#include "define.h"
//#include "interface.h"

#ifdef __cplusplus
};
#endif

#define INDENT        			1
#define SHOW_VERSION  			2
#define SHOW_CONFIG   			4
#define SHOW_COPYRIGHT 			8

#define XTRACE   				printf

#define STREAM_DURATION         10.0
#define STREAM_FRAME_RATE       25 /* 25 images/s */
#define STREAM_PIX_FMT          AV_PIX_FMT_YUV420P /* default pix_fmt */

#define SCALE_FLAGS 			SWS_BICUBIC
#define FILE_LEN                2048

#define VIDEO_FRAME_SIZE   (64*1024*2)
#define AUDIO_FRAME_SIZE   (320*4+1)

#define VIDEO_ID 0
#define AUDIO_ID 1

typedef struct GLNK_AudioDataFormat {
    int bitrate;
    int samplesRate;
    int channelNumber;
    enum AVSampleFormat sample_fmt;
    int iLayout;
}GLNK_AudioDataFormat;

typedef struct GLNK_VideoDataFormat {
    int width;
    int height;
    int framerate;
    int bitrate;
    int gopSize;
}GLNK_VideoDataFormat;

class StreamMuxer{

	typedef struct _IOFile{
		char inputName[FILE_LEN];
		char outputName[FILE_LEN];
	}IOFile;

	typedef struct {
		uint8_t audio_object_type;
		uint8_t sample_frequency_index;
		uint8_t channel_configuration;
	}AudioSpecificConfig;

public:
	
	StreamMuxer(char *filename);
	~StreamMuxer();

	//3
	int WriteFileTail();

	//2
	int InputData5(AVPacket &pkt, int iVideoIndex, int iAudioIndex);

	//1
	int SaveMediaInfo(GLNK_VideoDataFormat videoFormat,GLNK_AudioDataFormat audioFormat);


protected:
	
	int Init(AVFormatContext *pIfmtCtx);
	int Init2();
	int UnInit();
	int add_audio_stream(AVFormatContext *oc);
	int add_video_stream(AVFormatContext *oc);

	uint8_t * get_nal(uint32_t *len, uint8_t **offset, uint8_t *start, uint32_t total);
	uint32_t find_start_code(uint8_t *buf, uint32_t zeros_in_startcode);

	int WriteData(AVPacket &pkt);
	int ParseADTS(unsigned char *pBuffer,int len);
	int ParseSpsPps(unsigned char *data,int len);
	
	int getSampleIndex(unsigned int aSamples);

	int InputData(AVFormatContext *ifmt_ctx,AVPacket _pkt);
	int InputData2(AVPacket &pkt, int iVideoIndex, int iAudioIndex);
	int InputData3(AVPacket &pkt, int iVideoIndex, int iAudioIndex);//rtsp
	int InputData4(AVPacket &pkt, int iVideoIndex, int iAudioIndex);
	
	int GetH264FrameCnt(unsigned char * buffer,int len);
	
private:
	IOFile io_param;
	int    m_record_type;
	int    m_video_width;
	int    m_video_height;
	int    m_write_first;
	int    m_first_pts;
	int    m_find_first_key_frame;
	int    m_find_first_aac_adts_farme;

	int64_t m_first_video_pts;
	int64_t m_first_video_dts;
	int64_t m_first_audio_pts;
	int64_t m_first_audio_dts;
	int m_first_video_frame;
	int m_first_audio_frame;

	int    m_out_video_index;
	int    m_out_audio_index;
	int    m_in_video_index;
	int    m_in_audio_index;

	AVOutputFormat  *ofmt;
	AVFormatContext *ifmt_ctx;
	AVFormatContext *ofmt_ctx;
	AVBitStreamFilterContext *vbsf;
	AVBitStreamFilterContext *vvbsf;
	AVStream *m_pInStream[2];
	AVStream *m_pOutStream[2];

	GLNK_AudioDataFormat m_audioFormat;
	GLNK_VideoDataFormat m_videoFormat;
	AVBitStreamFilterContext * avcbsfc;
	AVBitStreamFilterContext* aacbsfc;
	unsigned char m_Sps[256];
	unsigned char m_Pps[256];
	int  m_ppsLen;
	int  m_spsLen;
	unsigned char m_ADTSHeader[7];
	AudioSpecificConfig m_aac_config;

	int m_video_stream_create_statue;
	int m_audio_stream_create_statue;

	int m_video_frame_cnt;
	int m_audio_frame_cnt;

	int m_MediaInit;

	pthread_mutex_t m_write_mutex;
	int m_stream_count;

	FILE *fp_h264;

	char m_videoBuf[VIDEO_FRAME_SIZE];
	char m_audioBuf[AUDIO_FRAME_SIZE];
};








#endif /* StreamMuxer_hpp */
