#include "VorbisDecoder.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define STB_VORBIS_NO_PUSHDATA_API
#include "vendor/stb_vorbis.c"

struct MCVorbis { stb_vorbis *file; unsigned int rate, frames; int channels; };
static uint32_t little32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}
/* Verify complete, single-stream Ogg pages before accepting a partial decode.
   Buffers are bounded by Ogg's 255 laces / 255 bytes per lace. */
static int validate_ogg(const char *path) {
    FILE *file = fopen(path, "rb");
    if (!file) return 1;
    uint32_t table[256];
    for (unsigned i=0; i<256; ++i) {
        uint32_t value = i << 24;
        for (int bit=0; bit<8; ++bit) value = (value << 1) ^ (value & 0x80000000 ? 0x04c11db7 : 0);
        table[i] = value;
    }
    unsigned char header[27], laces[255], body[65025];
    uint32_t serial=0, sequence=0;
    int first=1, ended=0, error=1;
    for (;;) {
        size_t size=fread(header,1,sizeof(header),file);
        if (size == 0) { error=(!first && ended && !ferror(file)) ? 0 : 1; break; }
        if (ended) { error=3; break; }
        if (size != sizeof(header) || memcmp(header,"OggS",4) || header[4] != 0 || (header[5]&~7)) break;
        if (first) {
            if (!(header[5]&2) || (header[5]&1)) break;
            serial=little32(header+14);
        } else if ((header[5]&2) || little32(header+14) != serial) { error=3; break; }
        if (little32(header+18) != sequence++) break;
        unsigned count=header[26], bytes=0;
        if (fread(laces,1,count,file) != count) break;
        for (unsigned i=0; i<count; ++i) bytes+=laces[i];
        if (fread(body,1,bytes,file) != bytes) break;
        uint32_t expected=little32(header+22), crc=0;
        memset(header+22,0,4);
        for (unsigned i=0; i<sizeof(header); ++i) crc=(crc<<8)^table[(crc>>24)^header[i]];
        for (unsigned i=0; i<count; ++i) crc=(crc<<8)^table[(crc>>24)^laces[i]];
        for (unsigned i=0; i<bytes; ++i) crc=(crc<<8)^table[(crc>>24)^body[i]];
        if (crc != expected) break;
        if (first && (bytes<7 || body[0]!=1 || memcmp(body+1,"vorbis",6))) { error=2; break; }
        first=0;
        if (header[5]&4) {
            if (little32(header+10) != 0 || little32(header+6) == UINT32_MAX) { error=4; break; }
            ended=1;
        }
    }
    fclose(file); return error;
}
MCVorbis *mc_vorbis_open(const char *path, int *error) {
    *error=validate_ogg(path);
    if (*error) return NULL;
    int upstream=0;
    stb_vorbis *file=stb_vorbis_open_filename(path,&upstream,NULL);
    if (!file) { *error=1000+upstream; return NULL; }
    stb_vorbis_info info=stb_vorbis_get_info(file);
    unsigned int frames=stb_vorbis_stream_length_in_samples(file);
    if (info.channels<1 || info.channels>2 || info.sample_rate<8000 || info.sample_rate>192000 || frames==0 || frames==UINT32_MAX) {
        stb_vorbis_close(file); *error=4; return NULL;
    }
    MCVorbis *decoder=malloc(sizeof(*decoder));
    if (!decoder) { stb_vorbis_close(file); *error=4; return NULL; }
    decoder->file=file; decoder->rate=info.sample_rate; decoder->frames=frames; decoder->channels=info.channels;
    *error=0; return decoder;
}
uint32_t mc_vorbis_rate(MCVorbis *d) { return d->rate; }
uint32_t mc_vorbis_frames(MCVorbis *d) { return d->frames; }
int mc_vorbis_channels(MCVorbis *d) { return d->channels; }
int mc_vorbis_read(MCVorbis *d, float *samples, int capacity) { return stb_vorbis_get_samples_float_interleaved(d->file,d->channels,samples,capacity); }
int mc_vorbis_error(MCVorbis *d) { return stb_vorbis_get_error(d->file); }
void mc_vorbis_close(MCVorbis *d) { if (d) { stb_vorbis_close(d->file); free(d); } }
