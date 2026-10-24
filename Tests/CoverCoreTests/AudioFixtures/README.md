# Generated audio fixtures

All ten files are original, deterministic 0.5-second 440 Hz sine-wave fixtures,
generated locally with FFmpeg 7.1 lavfi `sine`, not imported music or recordings.
No FFmpeg code or executable is shipped in the application.

Command: `ffmpeg -f lavfi -i sine=frequency=440:sample_rate=RATE:duration=0.5
-ac CHANNELS -c:a CODEC OUTPUT`.
Mono Vorbis is 44.1 kHz; all other files are stereo 48 kHz.
OGG/Vorbis uses libvorbis; opus.ogg uses libopus (an explicit unsupported-codec
test); FLAC uses flac; AIFF/CAF/WAV use PCM16; AAC/M4A use AAC; MP3 uses libmp3lame.
Decoded PCM is tested for duration, channels, actual nonzero samples and pitch.
The Ogg pages are also mutated/truncated/concatenated in temporary directories
to verify safe rejection without modifying these source fixtures.
