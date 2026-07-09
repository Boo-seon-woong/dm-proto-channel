/* Shared item-store layout for the disaggregated memcached store. Only the compute node interprets
 * this; the memory node just holds a byte region. KV_SLOT is a RUNTIME value (set via -V) so the
 * same binary can sweep value sizes; the memory node stays a fixed byte region and needs no rebuild
 * as long as the compute keeps NSLOTS*KV_SLOT <= that region. vlen is 32-bit (values up to ~4 MiB). */
#ifndef KV_LAYOUT_H
#define KV_LAYOUT_H
#include <stdint.h>
#include <string.h>

#define KV_KMAX   250                          /* memcached max key length */
#define KV_HDR    (1 + 1 + 4 + 4 + KV_KMAX)    /* state,klen,flags,vlen,key = 260 */
extern uint32_t KV_SLOT;                       /* runtime slot size (bytes); default 1024, set via -V */
#define KV_VMAX   (KV_SLOT - KV_HDR)            /* value capacity per slot (runtime) */

/* slot bytes: [0]=state(0 empty/1 occupied) [1]=klen [2..5]=flags(LE) [6..9]=vlen(LE)
 * [10..10+KMAX)=key  [KV_HDR..)=value */
static inline uint8_t  slot_state(const char *s){ return (uint8_t)s[0]; }
static inline uint8_t  slot_klen(const char *s){ return (uint8_t)s[1]; }
static inline uint32_t slot_flags(const char *s){ uint32_t f; memcpy(&f, s+2, 4); return f; }
static inline uint32_t slot_vlen(const char *s){ uint32_t v; memcpy(&v, s+6, 4); return v; }
static inline const char *slot_key(const char *s){ return s + 10; }
static inline const char *slot_val(const char *s){ return s + KV_HDR; }

static inline void slot_build(char *s, const char *k, uint8_t klen,
			      const char *v, uint32_t vlen, uint32_t flags){
	s[0] = 1; s[1] = klen;
	memcpy(s+2, &flags, 4);
	memcpy(s+6, &vlen, 4);
	memcpy(s+10, k, klen);
	if (vlen) memcpy(s + KV_HDR, v, vlen);
}
static inline int slot_key_matches(const char *s, const char *k, uint8_t klen){
	return slot_state(s) == 1 && slot_klen(s) == klen && !memcmp(slot_key(s), k, klen);
}

/* FNV-1a 64-bit hash → slot index. */
static inline uint64_t kv_hash(const char *k, size_t n){
	uint64_t h = 1469598103934665603ULL;
	for (size_t i = 0; i < n; i++){ h ^= (uint8_t)k[i]; h *= 1099511628211ULL; }
	return h;
}
#endif
