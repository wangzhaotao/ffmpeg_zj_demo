//
//  StreamMuxer.cpp
//
//  Created by xqk on 2017/4/28.
//  Copyright © 2017年 xhan. All rights reserved.
//  利用ffmpeg合成h264加aac为MP4


#include "streamMuxer.hpp"

int show_version();

StreamMuxer::StreamMuxer(char *filename)
{
	m_record_type = 0;
	m_video_width = 0;
	m_video_height = 0;
	m_write_first = 1;

	m_first_video_frame = 1;
	m_first_audio_frame = 1;

	m_first_video_pts = 0;
	m_first_video_dts = 0;
	m_first_audio_pts = 0;
	m_first_audio_dts = 0;

	m_find_first_key_frame = 0;
	m_find_first_aac_adts_farme = 0;

	m_out_video_index = -1;
	m_out_audio_index = -1;
	m_in_video_index  = -1;
	m_in_audio_index  = -1;

	ofmt = NULL;
	ifmt_ctx = NULL;
	ofmt_ctx = NULL;
	vbsf = NULL;
	vvbsf = NULL;
	m_MediaInit = 0;
	avcbsfc = NULL;
	aacbsfc = NULL;
	m_stream_count = 0;
	memset(&io_param,0,sizeof(io_param));
	memset(m_Sps, 0, sizeof(m_Sps));
	memset(m_Pps, 0, sizeof(m_Pps));
	memset(m_ADTSHeader, 0, sizeof(m_ADTSHeader));

	m_spsLen = 0;
	m_ppsLen = 0;

	if(NULL == filename){
		XTRACE("filename is invilid\n");
		return ;
	}

	strncpy(io_param.outputName,filename,FILE_LEN);
	io_param.outputName[FILE_LEN - 1] = '\0';

	m_video_stream_create_statue = 0;
	m_audio_stream_create_statue = 0;

	m_video_frame_cnt = 0;
	m_audio_frame_cnt = 0;
	
	memset(m_videoBuf,0,VIDEO_FRAME_SIZE);
	memset(m_audioBuf,0,AUDIO_FRAME_SIZE);

	pthread_mutex_init(&m_write_mutex, NULL);


}


int StreamMuxer::Init(AVFormatContext *ic)
{
	int ret = 0;

	av_register_all();

	avcodec_register_all();

	avformat_network_init();
	
	char *flag = NULL;
	if(0 ==  strncmp(io_param.outputName,"rtmp",4)){
		flag = (char *)"flv";
	}else if(0 ==  strncmp(io_param.outputName,"udp",3)){
		flag = (char *)"h264";
	}

	ret = avformat_alloc_output_context2(&ofmt_ctx, NULL, flag, io_param.outputName);
	if (!ofmt_ctx){
		XTRACE("Error:Could not create output context\n");
		UnInit();
		return -1;
	}

	ofmt = ofmt_ctx->oformat;

	ofmt->flags |= AVFMT_ALLOW_FLUSH;

	if (!(ofmt->flags & AVFMT_NOFILE)){
		ret = avio_open(&ofmt_ctx->pb, io_param.outputName, AVIO_FLAG_WRITE);
		if ( ret < 0 ){
			char errbuf[1024] = {0};
			av_strerror(ret,errbuf,1024);
			XTRACE("Error: Could not open output file. error code: %#x,\n error info:%s\n",ret,errbuf);
			return -1;
		}
	}

	AVDictionary *options = NULL;
	av_dict_set(&options, "rtsp_transport", "tcp", 0);
	/*开始写入文件头信息*/
	ret = avformat_write_header(ofmt_ctx, &options);
	if ( ret < 0 ){
		char errbuf[1024] = {0};
		av_strerror(ret,errbuf,1024);
		XTRACE("Error: Could not write file header. error code: %#x,\n error info:%s\n",ret,errbuf);
		return -1;
	}

	return 0;
}


int StreamMuxer::UnInit()
{
	int ret = 0;
		
	if (aacbsfc){
		av_bitstream_filter_close(aacbsfc);
		aacbsfc = NULL;
	}

	if (ofmt_ctx && !(ofmt_ctx->oformat->flags & AVFMT_NOFILE))
        avio_closep(&ofmt_ctx->pb);

    /* free the stream */
    //avformat_free_context(ofmt_ctx);
	
	XTRACE("xcvo unInit free output ctx\n");
	vbsf = NULL;
	if ( ret < 0 && ret != AVERROR_EOF ){
		XTRACE("Error: failed to write packet to output file.\n");
		return 1;
	}

	return 0;
}

StreamMuxer::~StreamMuxer()
{
	m_record_type = 0;
	m_video_width = 0;
	m_video_height = 0;
}

int StreamMuxer::InputData(AVFormatContext *ifmt_ctx,AVPacket pkt)
{
	int ret = 0;
	int keyframe = 0;

	pthread_mutex_lock(&m_write_mutex);

	if(m_write_first){
		ret = Init(ifmt_ctx);
		if(ret < 0){
			XTRACE("stream mux init failed\n");
			m_write_first = 1;
			pthread_mutex_unlock(&m_write_mutex);
			return 0;
		}
		m_write_first = 0;
	}

	if(pkt.stream_index == m_in_video_index){
		keyframe = pkt.flags & AV_PKT_FLAG_KEY;
	}

	if((pkt.stream_index != m_in_video_index) && \
		(pkt.stream_index != m_in_audio_index) ){
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("undefine pkt type\n");
			return -1;
	}

	if(0 == m_find_first_key_frame){
		if(keyframe){
			m_find_first_key_frame = 1;
		}else{
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("ignore non key frame\n");
			return 0;
		}
	}

	AVPacket newpkt;
	av_init_packet(&newpkt);
	av_copy_packet(&newpkt,&pkt);

	AVStream *in_stream = NULL, *out_stream = NULL;

	if(pkt.stream_index == m_in_video_index){
		in_stream = ifmt_ctx->streams[pkt.stream_index];
		out_stream = ofmt_ctx->streams[m_out_video_index];
		newpkt.stream_index = m_out_video_index;
	}
	else if(pkt.stream_index == m_in_audio_index){
		in_stream = ifmt_ctx->streams[pkt.stream_index];
		out_stream = ofmt_ctx->streams[m_out_audio_index];
		newpkt.stream_index = m_out_audio_index;
	}

	if( (pkt.stream_index == m_in_video_index ) && m_first_video_frame){
		m_first_video_frame = 0;
		m_first_video_pts = newpkt.pts;
		m_first_video_dts = newpkt.dts;
	}

	if( (pkt.stream_index == m_in_audio_index ) && m_first_audio_frame){
		m_first_audio_frame = 0;
		m_first_audio_pts = newpkt.pts;
		m_first_audio_dts = newpkt.dts;
	}

	if(pkt.stream_index == m_in_video_index){
		newpkt.pts = newpkt.pts - m_first_video_pts;
		newpkt.dts = newpkt.dts - m_first_video_dts;
	}else if(pkt.stream_index == m_in_audio_index){
		newpkt.pts = newpkt.pts - m_first_audio_pts;
		newpkt.dts = newpkt.dts - m_first_audio_dts;
	}

	in_stream->time_base.den = 1000;
	
	newpkt.pts = av_rescale_q_rnd(newpkt.pts, in_stream->time_base, out_stream->time_base, (enum AVRounding)(AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
	newpkt.dts = av_rescale_q_rnd(newpkt.dts, in_stream->time_base, out_stream->time_base, (enum AVRounding)(AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
	newpkt.duration = av_rescale_q(newpkt.duration, in_stream->time_base, out_stream->time_base);

	newpkt.pos = -1;

	if(newpkt.stream_index == m_out_video_index){

	}
       
	ret = av_write_frame(ofmt_ctx,&newpkt);
	if ( ret < 0 ){
		XTRACE("Error: muxing packet.\n");
	}

	//av_free_packet(&newpkt);
	av_packet_unref(&newpkt);

	pthread_mutex_unlock(&m_write_mutex);

	return 0;
	
}



int StreamMuxer::Init2()
{
	int ret = 0;
	char *flag = NULL;
	AVDictionary* options = NULL;

	av_register_all();
	avcodec_register_all();
	avformat_network_init();
	
	if(0 ==  strncmp(io_param.outputName,"rtmp",4)){
		flag = (char *)"flv";
	}else if(0 ==  strncmp(io_param.outputName,"udp",3)){
		flag = (char *)"h264";
	}else if(0 ==  strncmp(io_param.outputName,"rtsp",4)){
		flag = (char *)"rtsp";
	}else if(0 ==  strncmp(io_param.outputName + strlen(io_param.outputName) - 2,"ts",2)){
		flag = (char *)"mpegts";
	}

	ret = avformat_alloc_output_context2(&ofmt_ctx, NULL, flag, io_param.outputName);
	if (!ofmt_ctx){
		XTRACE("Error:Could not create output context\n");
		UnInit();
		return -1;
	}
	ofmt = ofmt_ctx->oformat;

	if(m_videoFormat.width != 0){
		ret = add_video_stream(ofmt_ctx);
		if(ret  < 0){
			XTRACE("add video stream failed\n");
			UnInit();
			return -1;
		}
		m_video_stream_create_statue = 1;
	}

	if(m_audioFormat.samplesRate != 0){
		ret = add_audio_stream(ofmt_ctx);
		if(ret  < 0){
			XTRACE("add audio stream failed\n");
			UnInit();
			return -1;
		}
		m_audio_stream_create_statue = 1;
	}

	if (!(ofmt->flags & AVFMT_NOFILE)){
		ret = avio_open(&ofmt_ctx->pb, io_param.outputName, AVIO_FLAG_WRITE);
		if ( ret < 0 ){
			char errbuf[1024] = {0};
			av_strerror(ret,errbuf,1024);
			XTRACE("Error: Could not open output file. error code: %#x,\n error info:%s\n",ret,errbuf);
			UnInit();
			return -1;
		}
	}

	if(0 ==  strncmp(io_param.outputName,"rtsp",4)){
		av_dict_set(&options, "rtsp_transport", "tcp", 0);
	}

	ret = avformat_write_header(ofmt_ctx, &options);
	if ( ret < 0 ){
		char errbuf[1024] = {0};
		av_strerror(ret,errbuf,1024);
		XTRACE("Error: Could not write file header. error code: %#x,\n error info:%s\n",ret,errbuf);
		UnInit();
		return -1;
	}

	return 0;
}


int StreamMuxer::InputData2(AVPacket &pkt, int iVideoIndex, int iAudioIndex)
{
	int ret = 0;
	int keyframe = 0;

	pthread_mutex_lock(&m_write_mutex);

	if( m_in_video_index < 0 ){
		m_in_video_index = iVideoIndex;
	}

	if( m_in_audio_index < 0 ){
		m_in_audio_index = iAudioIndex;
	}

	if((pkt.stream_index != m_in_video_index) && \
	   (pkt.stream_index != m_in_audio_index) ){
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("undefine pkt type\n");
			return -1;
	}

	if(pkt.stream_index == m_in_video_index){
		keyframe = (pkt.data[4] == 0x67 ? 1 : 0 );
	}

	if(pkt.stream_index == m_in_audio_index){
		if(0 == m_find_first_aac_adts_farme){
			memcpy(m_ADTSHeader,pkt.data,sizeof(m_ADTSHeader));
			ParseADTS(m_ADTSHeader, sizeof(m_ADTSHeader));
			m_find_first_aac_adts_farme = 1;
		}
	}

	if(0 == m_find_first_key_frame){
		if(keyframe){
			m_find_first_key_frame = 1;
			ParseSpsPps(pkt.data, pkt.size);
		}else{
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("ignore non key frame\n");
			return 0;
		}
	}

	if(m_write_first){
		ret = Init2();
		if(ret < 0){
			XTRACE("stream mux init failed\n");
			m_write_first = 1;
			pthread_mutex_unlock(&m_write_mutex);
			return 0;
		}
		m_write_first = 0;
	}

	if( (pkt.stream_index == m_in_video_index) &&
		!m_video_stream_create_statue ){
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("video stream create failed, can not write pkt\n");
			return -1;
	}

	if( (pkt.stream_index == m_in_audio_index) &&
		!m_audio_stream_create_statue ){
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("audio stream create failed, can not write pkt\n");
			return -1;
	}

	if(keyframe){

		unsigned char *buf = (unsigned char *)pkt.data;
		if(!buf){
			pthread_mutex_unlock(&m_write_mutex);
			return -1;
		}

		uint8_t *srcData = buf;
		uint8_t *offData = srcData;
		uint32_t dataLen = 0;
		uint8_t *nal = NULL;

		while(1){

			nal = get_nal(&dataLen, &offData, srcData, pkt.size);
			if(nal == NULL){
				break;
			}

			printf("contain sps pps key frame is 0x%02x\n",nal[0]);

			if(nal[0] != 0x65 )
				continue;

			pkt.flags |= AV_PKT_FLAG_KEY;

			int teLen = dataLen;

#if 1
			AVPacket pkt_t = pkt;

			unsigned char * mediaData = (unsigned char *)m_videoBuf;
			if(!mediaData)
				continue;

			memset(mediaData, 0, VIDEO_FRAME_SIZE);
			memcpy(mediaData + 4, nal, dataLen);

			pkt_t.data = mediaData;

			if(0 != strncmp(io_param.outputName,"rtsp",4)){
				
				mediaData[3] = (teLen & 0xff);
				mediaData[2] = ((teLen>>8) & 0xff);
				mediaData[1] = ((teLen>>16) & 0xff);
				mediaData[0] = ((teLen>>24) & 0xff);
			}else{
				
				mediaData[3] = 0x1;
			}

			pkt_t.size = dataLen + 4;
			WriteData(pkt_t);
			
#endif

		}

	}else{

		if(pkt.stream_index == m_in_video_index){

			unsigned char *buf = pkt.data;
			if(!buf){
				pthread_mutex_unlock(&m_write_mutex);
				return -1;
			}

			uint8_t *srcData = buf;
			uint8_t *offData = srcData;
			uint32_t dataLen = 0;
			uint8_t *nal = NULL;

			while(1){

				nal = get_nal(&dataLen, &offData, srcData, pkt.size);
				if(nal == NULL){
					break;
				}

				if(nal[0] == 0x67 || nal[0] == 0x68 || nal[0] == 0x6)
					continue;

				if(nal[0] == 0x65)
					pkt.flags |= AV_PKT_FLAG_KEY;

				int teLen = dataLen;

				AVPacket pkt_t = pkt;

				unsigned char * mediaData = (unsigned char *)m_videoBuf;
				if(!mediaData)
					continue;

				memset(mediaData, 0, dataLen);
				memcpy(mediaData + 4, nal, dataLen);

				pkt_t.data = mediaData;
				if(0 != strncmp(io_param.outputName,"rtsp",4)){

					mediaData[3] = (teLen & 0xff);
					mediaData[2] = ((teLen>>8) & 0xff);
					mediaData[1] = ((teLen>>16) & 0xff);
					mediaData[0] = ((teLen>>24) & 0xff);
				}else{
					mediaData[3] = 0x1;
				}

				pkt_t.size = dataLen + 4;

				WriteData(pkt_t);

			}

		}else{

			unsigned char *buf = pkt.data;
			if(!buf){
				pthread_mutex_unlock(&m_write_mutex);
				return -1;
			}

			int dataLen = pkt.size;
			AVPacket pkt_t = pkt;
			pkt_t.data = buf;
			pkt_t.size = dataLen;
			
			WriteData(pkt_t);
		}

	}

	pthread_mutex_unlock(&m_write_mutex);

	return 0;
}

int StreamMuxer::InputData3(AVPacket &pkt, int iVideoIndex, int iAudioIndex)
{
	int ret = 0;
	int keyframe = 0;

	pthread_mutex_lock(&m_write_mutex);

	if( m_in_video_index < 0 ){
		m_in_video_index = iVideoIndex;
	}

	if( m_in_audio_index < 0 ){
		m_in_audio_index = iAudioIndex;
	}

	if((pkt.stream_index != m_in_video_index) && \
		(pkt.stream_index != m_in_audio_index) ){
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("undefine pkt type\n");
			return -1;
	}

	if(pkt.stream_index == m_in_video_index){
		keyframe = (pkt.data[4] == 0x67 ? 1 : 0 );
	}

	if(pkt.stream_index == m_in_audio_index){
		if(0 == m_find_first_aac_adts_farme){
			memcpy(m_ADTSHeader,pkt.data,sizeof(m_ADTSHeader));
			ParseADTS(m_ADTSHeader, sizeof(m_ADTSHeader));
			m_find_first_aac_adts_farme = 1;
		}
	}

	if(0 == m_find_first_key_frame){
		if(keyframe){
			m_find_first_key_frame = 1;
			ParseSpsPps(pkt.data, pkt.size);
		}else{
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("ignore non key frame\n");
			return 0;
		}
	}

	if(m_write_first){
		ret = Init2();
		if(ret < 0){
			XTRACE("stream mux init failed\n");
			m_write_first = 1;
			pthread_mutex_unlock(&m_write_mutex);
			return 0;
		}
		m_write_first = 0;
	}

	if( (pkt.stream_index == m_in_video_index) &&
		!m_video_stream_create_statue ){
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("video stream create failed, can not write pkt\n");
			return -1;
	}

	if( (pkt.stream_index == m_in_audio_index) &&
		!m_audio_stream_create_statue ){
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("audio stream create failed, can not write pkt\n");
			return -1;
	}

	if(keyframe){

		unsigned char *buf = new unsigned char[pkt.size];
		if(!buf){
			pthread_mutex_unlock(&m_write_mutex);
			return -1;
		}

		memset(buf, 0, pkt.size);
		memcpy(buf,(unsigned char *)pkt.data,pkt.size);

		pkt.flags |= AV_PKT_FLAG_KEY;

		AVPacket pkt_t = pkt;
		pkt_t.data = buf;
		pkt_t.size = pkt.size;

		WriteData(pkt_t);

		delete [] buf;
		buf = NULL;

	}else{

		if(pkt.stream_index == m_in_video_index){

			unsigned char *buf = new unsigned char[pkt.size];
			if(!buf){
				pthread_mutex_unlock(&m_write_mutex);
				return -1;
			}

			memset(buf, 0, pkt.size);
			memcpy(buf,(unsigned char *)pkt.data,pkt.size);
			int dataLen = pkt.size;
			AVPacket pkt_t = pkt;
			pkt_t.data = buf;
			pkt_t.size = dataLen;
			if(buf[4] == 0x65)
				pkt_t.flags |= AV_PKT_FLAG_KEY;

			WriteData(pkt_t);

			delete [] buf;
			buf = NULL;
		
		}else{

			unsigned char *buf = new unsigned char[pkt.size];
			if(!buf){
				pthread_mutex_unlock(&m_write_mutex);
				return -1;
			}

			memset(buf, 0, pkt.size);
			memcpy(buf,(unsigned char *)pkt.data,pkt.size);
			int dataLen = pkt.size;
			AVPacket pkt_t = pkt;
			pkt_t.data = buf;
			pkt_t.size = dataLen;
			pkt_t.flags |= AV_PKT_FLAG_KEY;

			WriteData(pkt_t);

			delete [] buf;
			buf = NULL;

		}

	}

	pthread_mutex_unlock(&m_write_mutex);

	return 0;
}


int StreamMuxer::InputData4(AVPacket &pkt, int iVideoIndex, int iAudioIndex)
{
	int ret = 0;
	int keyframe = 0;

	pthread_mutex_lock(&m_write_mutex);

	if( m_in_video_index < 0 ){
		m_in_video_index = iVideoIndex;
	}

	if( m_in_audio_index < 0 ){
		m_in_audio_index = iAudioIndex;
	}

	if((pkt.stream_index != m_in_video_index) && \
		(pkt.stream_index != m_in_audio_index) ){
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("undefine pkt type\n");
			return -1;
	}

	if(pkt.stream_index == m_in_video_index){
		keyframe = (pkt.data[4] == 0x67 ? 1 : 0 );
	}

	//m_find_first_key_frame = 1;
	if(pkt.stream_index == m_in_audio_index){
		if(0 == m_find_first_aac_adts_farme){
			memcpy(m_ADTSHeader,pkt.data,sizeof(m_ADTSHeader));
			ParseADTS(m_ADTSHeader, sizeof(m_ADTSHeader));
			m_find_first_aac_adts_farme = 1;
		}
	}

	if(0 == m_find_first_key_frame){
		if(keyframe){
			m_find_first_key_frame = 1;
			ParseSpsPps(pkt.data, pkt.size);
		}else{
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("ignore non key frame\n");
			return 0;
		}
	}

	if(m_write_first){
		ret = Init2();
		if(ret < 0){
			XTRACE("stream mux init failed\n");
			m_write_first = 1;
			pthread_mutex_unlock(&m_write_mutex);
			return 0;
		}
		m_write_first = 0;
	}

	if( (pkt.stream_index == m_in_video_index) &&
		!m_video_stream_create_statue ){
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("video stream create failed, can not write pkt\n");
			return -1;
	}

	if( (pkt.stream_index == m_in_audio_index) &&
		!m_audio_stream_create_statue ){
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("audio stream create failed, can not write pkt\n");
			return -1;
	}

	static int iVideoFrameCnt = 0;
	static int iAudioFrameCnt = 0;

	if(keyframe){

		unsigned char *buf = new unsigned char[pkt.size];
		if(!buf){
			pthread_mutex_unlock(&m_write_mutex);
			return -1;
		}

		memset(buf, 0, pkt.size);
		memcpy(buf,(unsigned char *)pkt.data,pkt.size);

		uint8_t *srcData = buf;
		uint8_t *offData = srcData;
		uint32_t dataLen = 0;
		uint8_t *nal = NULL;

		while(1){

			nal = get_nal(&dataLen, &offData, srcData, pkt.size);
			if(nal == NULL){
				delete [] buf;
				buf = NULL;
				break;
			}

			printf("contain sps pps key frame is 0x%02x\n",nal[0]);

			if(nal[0] != 0x65)
				continue;

			pkt.flags |= AV_PKT_FLAG_KEY;

			//int teLen = dataLen;
			AVPacket pkt_t = pkt;

			unsigned char * mediaData = (unsigned char *)malloc(dataLen);
			if(!mediaData)
				continue;

			memset(mediaData, 0, dataLen);
			memcpy(mediaData, nal, dataLen);

			pkt_t.data = mediaData;

			if(0 != strncmp(io_param.outputName,"rtsp",4)){

// 				mediaData[3] = (teLen & 0xff);
// 				mediaData[2] = ((teLen>>8) & 0xff);
// 				mediaData[1] = ((teLen>>16) & 0xff);
// 				mediaData[0] = ((teLen>>24) & 0xff);
			}else{
				//mediaData[3] = 0x1;
			}

			pkt_t.size = dataLen;
			pkt_t.pts = pkt_t.dts = 1000/m_videoFormat.framerate*iVideoFrameCnt++;
			WriteData(pkt_t);

			free(mediaData);
		}

	}else{

		if(pkt.stream_index == m_in_video_index){

			unsigned char *buf = new unsigned char[pkt.size];
			if(!buf){
				pthread_mutex_unlock(&m_write_mutex);
				return -1;
			}


			memset(buf, 0, pkt.size);
			memcpy(buf,(unsigned char *)pkt.data,pkt.size);

			uint8_t *srcData = buf;
			uint8_t *offData = srcData;
			uint32_t dataLen = 0;
			uint8_t *nal = NULL;

			while(1){

				nal = get_nal(&dataLen, &offData, srcData, pkt.size);
				if(nal == NULL){
					//printf("p frame cnt is %d, pts is %lld\n",pFrameCnt,pkt.pts);
					delete [] buf;
					buf = NULL;
					break;
				}

				//printf("key frame is 0x%02x\n",nal[0]);

				//ignore sps and pps and sei 
				if(nal[0] == 0x67 || nal[0] == 0x68 || nal[0] == 0x6)
					continue;

				if(nal[0] == 0x65)
					pkt.flags |= AV_PKT_FLAG_KEY;

				//int teLen = dataLen;
				AVPacket pkt_t = pkt;

				unsigned char * mediaData = (unsigned char *)malloc(dataLen);
				if(!mediaData)
					continue;

				memset(mediaData, 0, dataLen);
				memcpy(mediaData, nal, dataLen);

				pkt_t.data = mediaData;
				if(0 != strncmp(io_param.outputName,"rtsp",4)){

// 					mediaData[3] = (teLen & 0xff);
// 					mediaData[2] = ((teLen>>8) & 0xff);
// 					mediaData[1] = ((teLen>>16) & 0xff);
// 					mediaData[0] = ((teLen>>24) & 0xff);
				}else{
					//mediaData[3] = 0x1;
				}

				pkt_t.size = dataLen;
				pkt_t.pts = pkt_t.dts = 1000/m_videoFormat.framerate*iVideoFrameCnt++;

				WriteData(pkt_t);

				free(mediaData);
			}

		}else{

			unsigned char *buf = new unsigned char[pkt.size];
			if(!buf){
				pthread_mutex_unlock(&m_write_mutex);
				return -1;
			}

			memset(buf, 0, pkt.size);
			memcpy(buf,(unsigned char *)pkt.data,pkt.size);
			int dataLen = pkt.size;
			AVPacket pkt_t = pkt;
			pkt_t.data = buf;
			pkt_t.size = dataLen;
			pkt_t.pts = pkt_t.dts = 1024*1000/m_audioFormat.samplesRate*iAudioFrameCnt++;

			WriteData(pkt_t);

			delete [] buf;
			buf = NULL;

		}

	}

	pthread_mutex_unlock(&m_write_mutex);

	return 0;
}

int StreamMuxer::InputData5(AVPacket &pkt, int iVideoIndex, int iAudioIndex)
{
	int ret = 0;
	int keyframe = 0;
	int nCopySize = 0;

	pthread_mutex_lock(&m_write_mutex);

	if( m_in_video_index < 0 ){
		m_in_video_index = iVideoIndex;
	}
	
	if( m_in_audio_index < 0 ){
		m_in_audio_index = iAudioIndex;
	}

	if((pkt.stream_index != m_in_video_index) && \
		(pkt.stream_index != m_in_audio_index) ){
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("undefine pkt type\n");
			return -1;
	}

	if(pkt.stream_index == m_in_video_index){
		if(pkt.data[4] == 0x67 || pkt.data[3] == 0x67)
			keyframe = 1;
		else
			keyframe = 0;
	}

	if(pkt.stream_index == m_in_audio_index){
		if(0 == m_find_first_aac_adts_farme){
			memcpy(m_ADTSHeader,pkt.data,sizeof(m_ADTSHeader));
			ParseADTS(m_ADTSHeader, sizeof(m_ADTSHeader));
			m_find_first_aac_adts_farme = 1;
		}
	}

	if(0 == m_find_first_key_frame){
        if(keyframe){
			m_find_first_key_frame = 1;
			ParseSpsPps(pkt.data, pkt.size);
        }else{
            pthread_mutex_unlock(&m_write_mutex);
            XTRACE("ignore non key frame\n");
            return 0;
        }
	}

	if(m_write_first){
		ret = Init2();
		if(ret < 0){
			XTRACE("stream mux init failed\n");
			m_write_first = 1;
			pthread_mutex_unlock(&m_write_mutex);
			return 0;
		}
		m_write_first = 0;
	}

	if( (pkt.stream_index == m_in_video_index) &&
		!m_video_stream_create_statue ){
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("video stream create failed, can not write pkt\n");
			return -1;
	}

	if( (pkt.stream_index == m_in_audio_index) &&
		!m_audio_stream_create_statue ){
			pthread_mutex_unlock(&m_write_mutex);
			XTRACE("audio stream create failed, can not write pkt\n");
			return -1;
	}

	if(keyframe){

		unsigned char *buf = (unsigned char *)m_videoBuf;
		if(!buf){
			pthread_mutex_unlock(&m_write_mutex);
			return -1;
		}

		memset(buf, 0, VIDEO_FRAME_SIZE);
		nCopySize = FFMIN(VIDEO_FRAME_SIZE,pkt.size);
		memcpy(buf,(unsigned char *)pkt.data,nCopySize);

		pkt.flags 		|= AV_PKT_FLAG_KEY;

		AVPacket pkt_t 	= pkt;
		pkt_t.data 		= buf;
		pkt_t.size 		= nCopySize;

		WriteData(pkt_t);

	}
	else
	{
		if(pkt.stream_index == m_in_video_index){

			unsigned char *buf = (unsigned char *)m_videoBuf;
			if(!buf){
				pthread_mutex_unlock(&m_write_mutex);
				return -1;
			}

			memset(buf, 0, VIDEO_FRAME_SIZE);
			
			nCopySize 		= FFMIN(VIDEO_FRAME_SIZE,pkt.size);
			memcpy(buf,(unsigned char *)pkt.data,nCopySize);
			int dataLen 	= nCopySize;
			AVPacket pkt_t 	= pkt;
			pkt_t.data 		= buf;
			pkt_t.size 		= dataLen;
			if(buf[4] == 0x65)
				pkt_t.flags |= AV_PKT_FLAG_KEY;

			WriteData(pkt_t);
		
		}
		else
		{
			unsigned char *buf = (unsigned char *)m_audioBuf;
			if(!buf){
				pthread_mutex_unlock(&m_write_mutex);
				return -1;
			}

			memset(buf, 0, AUDIO_FRAME_SIZE);
			
			nCopySize 		= FFMIN(AUDIO_FRAME_SIZE,pkt.size);
			memcpy(buf,(unsigned char *)pkt.data,nCopySize);
			int dataLen 	= nCopySize;
			AVPacket pkt_t 	= pkt;
			pkt_t.data 		= buf;
			pkt_t.size 		= dataLen;
			pkt_t.flags    |= AV_PKT_FLAG_KEY;

			WriteData(pkt_t);

		}

	}

	pthread_mutex_unlock(&m_write_mutex);

	return 0;
}


int StreamMuxer::ParseSpsPps(unsigned char *data,int len)
{
	if(!data)
		return -1;

	unsigned char *buf = new unsigned char[len];
	if(!buf)
		return -1;

	memcpy(buf,(unsigned char *)data,len);

	uint8_t *srcData = buf;
	uint8_t *offData = srcData;
	uint32_t dataLen = 0;
	uint8_t *nal = NULL;

	while(1){

		nal = get_nal(&dataLen, &offData, srcData, len);
		if(nal == NULL){
			delete [] buf;
			buf = NULL;
			break;
		}

		if(!m_spsLen || !m_ppsLen){

			if(nal[0] == 0x67){
				memcpy(m_Sps, nal, dataLen);
				m_spsLen = dataLen;
			}

			if(nal[0] == 0x68){
				memcpy(m_Pps, nal, dataLen);
				m_ppsLen = dataLen;
			}
		}

	}

	return 0;
}


int StreamMuxer::WriteFileTail()
{
	pthread_mutex_lock(&m_write_mutex);

	if(!m_write_first){

		if(ofmt_ctx)
			av_write_trailer(ofmt_ctx);

		UnInit();
	}

	pthread_mutex_unlock(&m_write_mutex);
	return 0;
}


int StreamMuxer::add_video_stream(AVFormatContext *oc)
{
	if(!m_MediaInit)
		return -1;

	AVStream *formatSt = avformat_new_stream(oc, NULL);
	if (!formatSt) {
		XTRACE("Could not allocate stream\n");
		return -1;
	}
	
	AVCodecContext *context = formatSt->codec;

	formatSt->id = ofmt_ctx->nb_streams - 1;

	context->codec_type 	= AVMEDIA_TYPE_VIDEO;
	context->codec_id 		= AV_CODEC_ID_H264;
	context->pix_fmt 		= AV_PIX_FMT_YUV420P;

	context->time_base.num  = 1;
	context->time_base.den  = m_videoFormat.framerate;

	formatSt->time_base.num = 1;
	formatSt->time_base.den = 90000;

	context->width 			= m_videoFormat.width;
	context->height 		= m_videoFormat.height;

// 	context->coded_width = m_videoFormat.width;
// 	context->coded_height = m_videoFormat.height;

	context->bit_rate 		= m_videoFormat.bitrate;
	context->gop_size 		= m_videoFormat.gopSize;

#if  0
	if( ( 0 == strncmp(io_param.outputName,"rtmp",4) ) )
	{
		if(m_spsLen && m_ppsLen && !formatSt->codec->extradata){

			unsigned char * extradata = new unsigned char[256];
			memset(extradata, 0, 256);
			extradata[0]=0x0;
			extradata[1]=0x0;
			extradata[2]=0x0;
			extradata[3]=0x01;
			memcpy(extradata+4, m_Sps, m_spsLen);

			extradata[m_spsLen + 4 + 0]=0x0;
			extradata[m_spsLen + 4 + 1]=0x0;
			extradata[m_spsLen + 4 + 2]=0x0;
			extradata[m_spsLen + 4 + 3]=0x01;
			memcpy(extradata+m_spsLen +4 + 4, m_Pps, m_ppsLen);

			formatSt->codec->extradata=extradata;
			formatSt->codec->extradata_size=m_spsLen + m_ppsLen + 4 + 4;

		}

	}else if(  0 == strncmp(io_param.outputName,"rtsp",4) )
	{
		unsigned char * extradata = new unsigned char[256];
		memset(extradata, 0, 256);
		extradata[0]=0x0;
		extradata[1]=0x0;
		extradata[2]=0x0;
		extradata[3]=0x01;
		memcpy(extradata+4, m_Sps, m_spsLen);

		extradata[m_spsLen + 4 + 0]=0x0;
		extradata[m_spsLen + 4 + 1]=0x0;
		extradata[m_spsLen + 4 + 2]=0x0;
		extradata[m_spsLen + 4 + 3]=0x01;
		memcpy(extradata+m_spsLen +4 + 4, m_Pps, m_ppsLen);

		formatSt->codec->extradata=extradata;
		formatSt->codec->extradata_size=m_spsLen + m_ppsLen + 4 + 4;
	}
	
#endif

	unsigned char * extradata = new unsigned char[256];
	memset(extradata, 0, 256);
	extradata[0]=0x0;
	extradata[1]=0x0;
	extradata[2]=0x0;
	extradata[3]=0x01;
	memcpy(extradata+4, m_Sps, m_spsLen);

	extradata[m_spsLen + 4 + 0]=0x0;
	extradata[m_spsLen + 4 + 1]=0x0;
	extradata[m_spsLen + 4 + 2]=0x0;
	extradata[m_spsLen + 4 + 3]=0x01;
	memcpy(extradata+m_spsLen +4 + 4, m_Pps, m_ppsLen);

	formatSt->codec->extradata=extradata;
	formatSt->codec->extradata_size=m_spsLen + m_ppsLen + 4 + 4;


	if (oc->oformat->flags & AVFMT_GLOBALHEADER)
		context->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;

	m_pOutStream[AVMEDIA_TYPE_VIDEO] =  formatSt;

	m_out_video_index = formatSt->index;

	return 0;
}


int StreamMuxer::add_audio_stream(AVFormatContext *oc)
{
	if(!m_MediaInit)
		return -1;

	AVStream *formatSt = avformat_new_stream(oc, NULL);
	if (!formatSt) {
		XTRACE("Could not allocate stream\n");
		return -1;
	}

	formatSt->id = ofmt_ctx->nb_streams - 1;

	AVCodecContext *context = formatSt->codec;

	context->codec_type = AVMEDIA_TYPE_AUDIO;
	context->codec_id = AV_CODEC_ID_AAC;

	//AV_SAMPLE_FMT_S16P
	context->sample_fmt  = m_audioFormat.sample_fmt;
	context->sample_rate = m_audioFormat.samplesRate;
	context->channel_layout = m_audioFormat.iLayout;//AV_CH_LAYOUT_STEREO;
	context->channels    = m_audioFormat.channelNumber;

	//if(0 != strncmp(io_param.outputName,"rtsp",4))
	{
		formatSt->time_base.num = 1;
		formatSt->time_base.den = m_audioFormat.samplesRate;

		context->time_base.num = 1;
		context->time_base.den = m_audioFormat.samplesRate;
		context->bit_rate    = 64000;
		context->frame_size  = 1024;
	}

#if 1
	unsigned char indexBuffer[2]={0};
	//aac
	m_aac_config.audio_object_type = 1;
	m_aac_config.sample_frequency_index = getSampleIndex(m_audioFormat.samplesRate);  // 8-->16k sample rate
	m_aac_config.channel_configuration = m_audioFormat.channelNumber;

	uint8_t audio_object_type = m_aac_config.audio_object_type + 1;
	indexBuffer[0] = (audio_object_type << 3) | (m_aac_config.sample_frequency_index >> 1);
	indexBuffer[1] = ((m_aac_config.sample_frequency_index & 0x01) << 7) \
		| (m_aac_config.channel_configuration << 3);
	context->extradata_size = sizeof(indexBuffer);;
	context->extradata = (uint8_t*)malloc(2);
	memcpy(context->extradata, indexBuffer,2);
#endif

	if (oc->oformat->flags & AVFMT_GLOBALHEADER)
		context->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;

	m_pOutStream[AVMEDIA_TYPE_AUDIO] =  formatSt;

	m_out_audio_index = formatSt->index;

	return 0;
}

int StreamMuxer::SaveMediaInfo(GLNK_VideoDataFormat videoFormat,GLNK_AudioDataFormat audioFormat)
{
	if(!m_MediaInit){
		m_MediaInit = 1;
	}else{
		return 0;
	}

	m_videoFormat = videoFormat;
	m_audioFormat = audioFormat;
	return 0;
}


uint32_t StreamMuxer::find_start_code(uint8_t *buf, uint32_t zeros_in_startcode)
{
	uint32_t info;
	uint32_t i;

	info = 1;
	if ((info = (buf[zeros_in_startcode] != 1) ? 0 : 1) == 0)
		return 0;

	for (i = 0; i < zeros_in_startcode; i++)
		if (buf[i] != 0)
		{
			info = 0;
			break;
		};

	return info;
}


uint8_t * StreamMuxer::get_nal(uint32_t *len, uint8_t **offset, uint8_t *start, uint32_t total)
{
	uint8_t *q ;
	uint8_t *p  =  *offset;
	*len = 0;

	if ((p - start) >= total)
		return NULL;

	//find first 0001
	int info1 = 0;
	int info2 = 0;

	while(1) {

		info1 = 0;
		info2 = 0;

		if( ( info1 =  find_start_code(p, 3)) || ( info2 = find_start_code(p, 2))){
			break;
		}

		p++;
		if ((p - start) >= total)
			return NULL;
	}

	q = p + (info1 == 1 ? 4 : 3);
	p = q;

	//q = p;
	//p = p + (info1 == 1 ? 4 : 3);

	//find second start code
	while(1) {

		info1 = 0;
		info2 = 0;

		if( ( info1 =  find_start_code(p, 3)) || ( info2 = find_start_code(p, 2))){
			break;
		}

		p++;
		if ((p - start) >= total)
			break;
	}

	*len = (p - q);
	*offset = p;
	return q;
}



int StreamMuxer::WriteData(AVPacket &pkt)
{
	int ret = 0;
	AVPacket newpkt;
	memset(&newpkt,0,sizeof(AVPacket));
	av_init_packet(&newpkt);
	newpkt = pkt;

	//ret = av_packet_from_data(&newpkt,pkt.data,pkt.size);

	if(pkt.stream_index == m_in_video_index){
		newpkt.stream_index = m_out_video_index;
	}
	else if(pkt.stream_index == m_in_audio_index){
		newpkt.stream_index = m_out_audio_index;
	}

	if( (pkt.stream_index == m_in_video_index ) && m_first_video_frame){
		m_first_video_frame = 0;
		m_first_video_pts = newpkt.pts;
		m_first_video_dts = newpkt.dts;
	}

	if( (pkt.stream_index == m_in_audio_index ) && m_first_audio_frame){
		m_first_audio_frame = 0;
		m_first_audio_pts = newpkt.pts;
		m_first_audio_dts = newpkt.dts;
	}

	if(pkt.stream_index == m_in_video_index){
	}

	if(pkt.stream_index == m_in_audio_index){
		newpkt.data = newpkt.data + 7;
		newpkt.size = newpkt.size - 7;
	}

	AVRational time_base_out;
	AVRational time_base_in;
	time_base_in.den = 1000;
	time_base_in.num = 1;

	if(pkt.stream_index == m_in_video_index){
		newpkt.pts = newpkt.pts - m_first_video_pts;
		newpkt.dts = newpkt.dts - m_first_video_dts;
		time_base_out = m_pOutStream[AVMEDIA_TYPE_VIDEO]->time_base;
	}else if(pkt.stream_index == m_in_audio_index){
		newpkt.pts = newpkt.pts - m_first_audio_pts;
		newpkt.dts = newpkt.dts - m_first_audio_dts;
		time_base_out = m_pOutStream[AVMEDIA_TYPE_AUDIO]->time_base;
		newpkt.flags |= AV_PKT_FLAG_KEY;
	}
	
	newpkt.pts  = av_rescale_q_rnd(newpkt.pts, time_base_in, time_base_out, (AVRounding)(AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
	newpkt.dts = av_rescale_q_rnd(newpkt.dts, time_base_in, time_base_out, (enum AVRounding)(AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
	newpkt.duration = av_rescale_q(newpkt.duration, time_base_in, time_base_out);
	newpkt.pos = -1;

	if(newpkt.stream_index == m_out_video_index){
// 		printf("[video data is 0x%02x  0x%02x 0x%02x 0x%02x 0x%02x]\n",newpkt.data[0],
// 			newpkt.data[1],newpkt.data[2],newpkt.data[3],newpkt.data[4]);
	}

	if(newpkt.stream_index == m_out_video_index){
		//char *str = newpkt.stream_index == m_out_video_index ? (char *)"video pkt" : (char *)"audio pkt";
		//printf(" %s data stream_index:%d,pts:%lld dts:%lld\n",str,newpkt.stream_index,newpkt.pts,newpkt.dts);
		//printf("2222 video pts is %lld, dts is %lld\n",pkt.pts,pkt.dts);
	}

  	ret = av_interleaved_write_frame(ofmt_ctx,&newpkt);
	if ( ret < 0 ){
		XTRACE("Error: muxing packet.\n");
		char errbuf[1024] = {0};
		av_strerror(ret,errbuf,1024);
		XTRACE("Error. error code: %#x,error info:%s\n",ret,errbuf);
	}
	return 0;
}


int StreamMuxer::ParseADTS(unsigned char *pBuffer,int len)
{

	char frequence_str[128] = {0};

	if (pBuffer == NULL) {
		return -1;
	}

	m_aac_config.audio_object_type = (pBuffer[2] & 0xc0) >> 6;
	m_aac_config.sample_frequency_index = (pBuffer[2] & 0x3c) >> 2;
	m_aac_config.channel_configuration = (pBuffer[3] & 0xc0) >> 6;


	switch(m_aac_config.sample_frequency_index){  
		 case 0: sprintf(frequence_str,"96000Hz");break;  
		 case 1: sprintf(frequence_str,"88200Hz");break;  
		 case 2: sprintf(frequence_str,"64000Hz");break;  
		 case 3: sprintf(frequence_str,"48000Hz");break;  
		 case 4: sprintf(frequence_str,"44100Hz");break;  
		 case 5: sprintf(frequence_str,"32000Hz");break;  
		 case 6: sprintf(frequence_str,"24000Hz");break;  
		 case 7: sprintf(frequence_str,"22050Hz");break;  
		 case 8: sprintf(frequence_str,"16000Hz");break;  
		 case 9: sprintf(frequence_str,"12000Hz");break;  
		 case 10: sprintf(frequence_str,"11025Hz");break;  
		 case 11: sprintf(frequence_str,"8000Hz");break;  
		 default:sprintf(frequence_str,"unknown");break;  
	} 

	XTRACE("aac cfg object_type:%d sample_rate:%d channal:%d\n",\
		m_aac_config.audio_object_type,m_aac_config.sample_frequency_index,\
		m_aac_config.channel_configuration);


	XTRACE("adts header 0x%02x 0x%02x 0x%02x 0x%02x 0x%02x 0x%02x 0x%02x \n",
		pBuffer[0],pBuffer[1],pBuffer[2],pBuffer[3],pBuffer[4],pBuffer[5],pBuffer[6]);

	return 0;
}

int StreamMuxer::getSampleIndex(unsigned int aSamples)
{
	switch(aSamples){
	case 96000: return 0;
	case 88200: return 1;
	case 64000: return 2;
	case 48000: return 3;
	case 44100: return 4;
	case 32000: return 5;
	case 24000: return 6;
	case 22050: return 7;
	case 16000: return 8;
	case 12000: return 9;
	case 11025: return 10;
	case 8000:  return 11;
	case 7350:  return 12;
	default:    return 0;
	}

}



int StreamMuxer::GetH264FrameCnt(unsigned char * buffer,int len)
{

	unsigned char *buf = buffer;
	if(buf == NULL){
		XTRACE("param is invalid");
		return -1;
	}

	uint8_t *srcData 	= buf;
	uint8_t *offData 	= srcData;
	uint32_t dataLen 	= 0;
	uint8_t *nal 		= NULL;

	int nFrameCnt 		= 0;
	
	while(1){

		nal = get_nal(&dataLen, &offData, srcData, len);
		if(nal == NULL){
			break;
		}

		//TRACE("contain sps pps key frame is 0x%02x",nal[0]);

		if(nal[0] == 0x67 || nal[0] == 0x68 || nal[0] == 0x6 )
			continue;
		
//		int teLen = dataLen;

		nFrameCnt ++;
		
#if 0
		AVPacket pkt_t = pkt;

		unsigned char * mediaData = (unsigned char *)m_videoBuf;
		if(!mediaData)
			continue;

		memset(mediaData, 0, VIDEO_FRAME_SIZE);
		memcpy(mediaData + 4, nal, dataLen);

		pkt_t.data = mediaData;

		if(0 != strncmp(io_param.outputName,"rtsp",4)){
			
			mediaData[3] = (teLen & 0xff);
			mediaData[2] = ((teLen>>8) & 0xff);
			mediaData[1] = ((teLen>>16) & 0xff);
			mediaData[0] = ((teLen>>24) & 0xff);
		}else{
			
			mediaData[3] = 0x1;
		}

		pkt_t.size = dataLen + 4;
		WriteData(pkt_t);
		
#endif

	}

	XTRACE("video frame cnt is %d",nFrameCnt);
	
	return nFrameCnt;
	
}
