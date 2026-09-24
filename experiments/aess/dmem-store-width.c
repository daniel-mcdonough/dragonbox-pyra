/*
 * Write the AESS MM_DL_LP mmap ring with 32-, 16- and 8-bit stores and with
 * memcpy, then read it back. The DSP memory keeps only the 32-bit writes.
 * Run on the Pyra with PulseAudio out of the way; the stream is never started,
 * so it makes no sound:
 *
 *   gcc -O2 -Wall -o dmem-store-width dmem-store-width.c -lasound
 *   pasuspender -- ./dmem-store-width
 */
#include <alsa/asoundlib.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

static int check(volatile uint32_t *w, size_t nw, uint32_t (*pat)(size_t), const char *what)
{
	size_t bad = 0, first = (size_t)-1;
	for (size_t i = 0; i < nw; i++)
		if (w[i] != pat(i)) { if (first == (size_t)-1) first = i; bad++; }
	printf("%-34s %zu/%zu words wrong", what, bad, nw);
	if (bad) printf(" (first at word %zu: got %08x want %08x)", first, w[first], pat(first));
	printf("\n");
	return bad != 0;
}
static uint32_t pa(size_t i) { return 0xA5000000u | (uint32_t)i; }
static uint32_t pb(size_t i) { return 0x5A000000u ^ (uint32_t)(i * 2654435761u); }
static uint32_t pc(size_t i) { return 0x3C3C0000u + (uint32_t)i * 7; }
static uint32_t pd(size_t i) { return 0x12340000u + (uint32_t)i * 13; }
static uint32_t pe(size_t i) { return 0x77000000u + (uint32_t)i * 3; }

int main(void)
{
	snd_pcm_t *h; snd_pcm_hw_params_t *p; int e;
	if ((e = snd_pcm_open(&h, "hw:CARD=L15,DEV=5", SND_PCM_STREAM_PLAYBACK, 0)) < 0) { printf("open %s\n", snd_strerror(e)); return 1; }
	snd_pcm_hw_params_alloca(&p); snd_pcm_hw_params_any(h, p);
	snd_pcm_hw_params_set_access(h, p, SND_PCM_ACCESS_MMAP_INTERLEAVED);
	snd_pcm_hw_params_set_format(h, p, SND_PCM_FORMAT_S16_LE);
	snd_pcm_hw_params_set_channels(h, p, 2);
	snd_pcm_hw_params_set_rate(h, p, 48000, 0);
	snd_pcm_hw_params_set_period_size(h, p, 1536, 0);
	snd_pcm_hw_params_set_buffer_size(h, p, 6144);
	if ((e = snd_pcm_hw_params(h, p)) < 0) { printf("hw_params %s\n", snd_strerror(e)); return 1; }
	const snd_pcm_channel_area_t *a; snd_pcm_uframes_t off, fr = 6144;
	if ((e = snd_pcm_mmap_begin(h, &a, &off, &fr)) < 0) { printf("mmap_begin %s\n", snd_strerror(e)); return 1; }
	uint8_t *base = (uint8_t *)a[0].addr + off * 4;
	size_t nb = fr * 4, nw = nb / 4;
	printf("mapped %zu frames at %p (offset %lu)\n", (size_t)fr, base, (unsigned long)off);
	volatile uint32_t *w = (volatile uint32_t *)base;
	volatile uint16_t *hw = (volatile uint16_t *)base;
	volatile uint8_t *b = (volatile uint8_t *)base;
	uint32_t tmp[6144];

	for (size_t i = 0; i < nw; i++) w[i] = pa(i);
	check(w, nw, pa, "32-bit stores");

	for (size_t i = 0; i < nw; i++) { uint32_t v = pb(i); hw[2*i] = v & 0xffff; hw[2*i+1] = v >> 16; }
	check(w, nw, pb, "16-bit stores");

	for (size_t i = 0; i < nw; i++) { uint32_t v = pc(i); for (int k = 0; k < 4; k++) b[4*i+k] = v >> (8*k); }
	check(w, nw, pc, "8-bit stores");

	for (size_t i = 0; i < nw; i++) tmp[i] = pd(i);
	memcpy(base, tmp, nb);
	check(w, nw, pd, "memcpy whole ring");

	/* memcpy in odd frame-count chunks, like a resampler's output */
	for (size_t i = 0; i < nw; i++) tmp[i] = pe(i);
	size_t pos = 0, sizes[] = {1411, 1537, 17, 1103, 5, 999, 1071};
	for (int k = 0; pos < nw; k = (k + 1) % 7) {
		size_t n = sizes[k]; if (pos + n > nw) n = nw - pos;
		memcpy(base + pos * 4, (uint8_t *)tmp + pos * 4, n * 4); pos += n;
	}
	check(w, nw, pe, "memcpy odd frame-count chunks");

	snd_pcm_close(h);
	return 0;
}
