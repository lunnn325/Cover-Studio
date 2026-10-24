#ifndef MY_COVER_VORBIS_DECODER_H
#define MY_COVER_VORBIS_DECODER_H
#include <stdint.h>
typedef struct MCVorbis MCVorbis;
/* Error 1: invalid/incomplete Ogg; 2: non-Vorbis; 3: chained streams;
   4: unsupported channels/rate/length; 1000+: upstream decoder error. */
MCVorbis *mc_vorbis_open(const char *path, int *error);
uint32_t mc_vorbis_rate(MCVorbis *decoder);
uint32_t mc_vorbis_frames(MCVorbis *decoder);
int mc_vorbis_channels(MCVorbis *decoder);
int mc_vorbis_read(MCVorbis *decoder, float *samples, int float_capacity);
int mc_vorbis_error(MCVorbis *decoder);
void mc_vorbis_close(MCVorbis *decoder);
#endif
