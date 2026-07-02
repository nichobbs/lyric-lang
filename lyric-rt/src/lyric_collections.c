/* lyric_collections.c — List and Map kernels (D-N-012).
 *
 * Both containers store elements/values in 64-bit slots.  Scalars are
 * widened to 64 bits by the codegen; reference elements are ARC
 * pointers that the container retains on insert and releases on
 * removal / overwrite / destruction (ARC Rules 2, 3, 7).
 *
 * The Map is open-addressing with linear probing.  String keys hash via
 * SipHash-2-4 over the UTF-8 data (keyed with a fixed key: hashing here
 * is for distribution, not DoS resistance — Lyric maps are in-process
 * only); integer keys use Fibonacci multiplicative hashing.
 */
#include "lyric_rt.h"

#include <stdlib.h>
#include <string.h>

/* ── List ──────────────────────────────────────────────────────────── */

void lyric_list_dtor(void* obj) {
    LyricList* l = (LyricList*)obj;
    if (l->elems_are_refs) {
        for (int64_t i = 0; i < l->len; i++) {
            lyric_release((void*)(intptr_t)l->data[i]);
        }
    }
    free(l->data);
}

LyricList* lyric_list_new(int32_t elems_are_refs) {
    LyricList* l = (LyricList*)lyric_alloc(sizeof(LyricList));
    atomic_store_explicit(&l->rc, 1, memory_order_relaxed);
    l->dtor = lyric_list_dtor;
    l->data = 0;
    l->len = 0;
    l->cap = 0;
    l->elems_are_refs = elems_are_refs;
    return l;
}

static void list_grow(LyricList* l, int64_t need) {
    if (need <= l->cap) return;
    int64_t cap = l->cap < 8 ? 8 : l->cap;
    while (cap < need) cap *= 2;
    int64_t* data = (int64_t*)lyric_alloc((uint64_t)cap * sizeof(int64_t));
    if (l->len > 0) memcpy(data, l->data, (size_t)l->len * sizeof(int64_t));
    free(l->data);
    l->data = data;
    l->cap = cap;
}

void lyric_list_push(LyricList* list, int64_t val) {
    list_grow(list, list->len + 1);
    if (list->elems_are_refs) lyric_retain((void*)(intptr_t)val);
    list->data[list->len] = val;
    list->len++;
}

int64_t lyric_list_get(LyricList* list, int64_t idx) {
    if (idx < 0 || idx >= list->len) {
        lyric_panic_msg("list index out of bounds", "lyric_collections.c", __LINE__);
    }
    return list->data[idx];
}

void lyric_list_set(LyricList* list, int64_t idx, int64_t val) {
    if (idx < 0 || idx >= list->len) {
        lyric_panic_msg("list index out of bounds", "lyric_collections.c", __LINE__);
    }
    if (list->elems_are_refs) {
        lyric_retain((void*)(intptr_t)val);
        lyric_release((void*)(intptr_t)list->data[idx]);
    }
    list->data[idx] = val;
}

void lyric_list_remove_at(LyricList* list, int64_t idx) {
    if (idx < 0 || idx >= list->len) {
        lyric_panic_msg("list index out of bounds", "lyric_collections.c", __LINE__);
    }
    if (list->elems_are_refs) lyric_release((void*)(intptr_t)list->data[idx]);
    memmove(&list->data[idx], &list->data[idx + 1],
            (size_t)(list->len - idx - 1) * sizeof(int64_t));
    list->len--;
}

int64_t lyric_list_len(LyricList* list) {
    return list->len;
}

void lyric_list_clear(LyricList* list) {
    if (list->elems_are_refs) {
        for (int64_t i = 0; i < list->len; i++) {
            lyric_release((void*)(intptr_t)list->data[i]);
        }
    }
    list->len = 0;
}

/* ── SipHash-2-4 ───────────────────────────────────────────────────── */

#define SIP_ROTL(x, b) (uint64_t)(((x) << (b)) | ((x) >> (64 - (b))))
#define SIP_ROUND()          \
    do {                     \
        v0 += v1;            \
        v1 = SIP_ROTL(v1, 13); \
        v1 ^= v0;            \
        v0 = SIP_ROTL(v0, 32); \
        v2 += v3;            \
        v3 = SIP_ROTL(v3, 16); \
        v3 ^= v2;            \
        v0 += v3;            \
        v3 = SIP_ROTL(v3, 21); \
        v3 ^= v0;            \
        v2 += v1;            \
        v1 = SIP_ROTL(v1, 17); \
        v1 ^= v2;            \
        v2 = SIP_ROTL(v2, 32); \
    } while (0)

static uint64_t siphash24(const uint8_t* data, uint64_t len) {
    /* Fixed key: in-process hash distribution only. */
    const uint64_t k0 = 0x0706050403020100ULL;
    const uint64_t k1 = 0x0f0e0d0c0b0a0908ULL;
    uint64_t v0 = 0x736f6d6570736575ULL ^ k0;
    uint64_t v1 = 0x646f72616e646f6dULL ^ k1;
    uint64_t v2 = 0x6c7967656e657261ULL ^ k0;
    uint64_t v3 = 0x7465646279746573ULL ^ k1;
    uint64_t b = len << 56;
    const uint8_t* end = data + (len - (len % 8));
    for (; data != end; data += 8) {
        uint64_t m;
        memcpy(&m, data, 8);
        v3 ^= m;
        SIP_ROUND();
        SIP_ROUND();
        v0 ^= m;
    }
    switch (len % 8) {
        case 7: b |= (uint64_t)data[6] << 48; /* fallthrough */
        case 6: b |= (uint64_t)data[5] << 40; /* fallthrough */
        case 5: b |= (uint64_t)data[4] << 32; /* fallthrough */
        case 4: b |= (uint64_t)data[3] << 24; /* fallthrough */
        case 3: b |= (uint64_t)data[2] << 16; /* fallthrough */
        case 2: b |= (uint64_t)data[1] << 8;  /* fallthrough */
        case 1: b |= (uint64_t)data[0];       /* fallthrough */
        case 0: break;
    }
    v3 ^= b;
    SIP_ROUND();
    SIP_ROUND();
    v0 ^= b;
    v2 ^= 0xff;
    SIP_ROUND();
    SIP_ROUND();
    SIP_ROUND();
    SIP_ROUND();
    return v0 ^ v1 ^ v2 ^ v3;
}

/* ── Map ───────────────────────────────────────────────────────────── */

typedef struct {
    int64_t key;
    int64_t val;
    uint8_t state; /* 0 = empty, 1 = occupied, 2 = tombstone */
} LyricMapSlot;

struct LyricMap {
    _Atomic int32_t rc;
    void (*dtor)(void*);
    LyricMapSlot*   slots;
    int64_t         cap;   /* power of two */
    int64_t         len;   /* occupied slots */
    int64_t         used;  /* occupied + tombstones */
    int32_t         keys_are_strings;
    int32_t         vals_are_refs;
};

static uint64_t map_hash(LyricMap* m, int64_t key) {
    if (m->keys_are_strings) {
        LyricString* s = (LyricString*)(intptr_t)key;
        return siphash24(LYRIC_STRING_DATA(s), (uint64_t)s->len);
    }
    /* Fibonacci multiplicative hash. */
    return (uint64_t)key * 0x9E3779B97F4A7C15ULL;
}

static int32_t map_key_eq(LyricMap* m, int64_t a, int64_t b) {
    if (m->keys_are_strings) {
        return lyric_string_eq((LyricString*)(intptr_t)a, (LyricString*)(intptr_t)b);
    }
    return a == b;
}

void lyric_map_dtor(void* obj) {
    LyricMap* m = (LyricMap*)obj;
    for (int64_t i = 0; i < m->cap; i++) {
        if (m->slots[i].state == 1) {
            if (m->keys_are_strings) lyric_release((void*)(intptr_t)m->slots[i].key);
            if (m->vals_are_refs) lyric_release((void*)(intptr_t)m->slots[i].val);
        }
    }
    free(m->slots);
}

LyricMap* lyric_map_new(int32_t keys_are_strings, int32_t vals_are_refs) {
    LyricMap* m = (LyricMap*)lyric_alloc(sizeof(LyricMap));
    atomic_store_explicit(&m->rc, 1, memory_order_relaxed);
    m->dtor = lyric_map_dtor;
    m->slots = 0;
    m->cap = 0;
    m->len = 0;
    m->used = 0;
    m->keys_are_strings = keys_are_strings;
    m->vals_are_refs = vals_are_refs;
    return m;
}

static void map_rehash(LyricMap* m, int64_t newCap) {
    LyricMapSlot* old = m->slots;
    int64_t oldCap = m->cap;
    m->slots = (LyricMapSlot*)lyric_alloc((uint64_t)newCap * sizeof(LyricMapSlot));
    memset(m->slots, 0, (size_t)newCap * sizeof(LyricMapSlot));
    m->cap = newCap;
    m->used = m->len;
    for (int64_t i = 0; i < oldCap; i++) {
        if (old[i].state == 1) {
            uint64_t h = map_hash(m, old[i].key);
            int64_t j = (int64_t)(h & (uint64_t)(newCap - 1));
            while (m->slots[j].state == 1) j = (j + 1) & (newCap - 1);
            m->slots[j].key = old[i].key;
            m->slots[j].val = old[i].val;
            m->slots[j].state = 1;
        }
    }
    free(old);
}

/* Returns the slot index for `key`: the occupied slot when present,
 * otherwise the first insertable (empty or tombstone) slot. */
static int64_t map_find(LyricMap* m, int64_t key) {
    uint64_t h = map_hash(m, key);
    int64_t i = (int64_t)(h & (uint64_t)(m->cap - 1));
    int64_t first_tomb = -1;
    for (;;) {
        LyricMapSlot* s = &m->slots[i];
        if (s->state == 0) return first_tomb >= 0 ? first_tomb : i;
        if (s->state == 2) {
            if (first_tomb < 0) first_tomb = i;
        } else if (map_key_eq(m, s->key, key)) {
            return i;
        }
        i = (i + 1) & (m->cap - 1);
    }
}

void lyric_map_set(LyricMap* map, int64_t key, int64_t val) {
    if (map->cap == 0 || (map->used + 1) * 4 >= map->cap * 3) {
        map_rehash(map, map->cap == 0 ? 16 : map->cap * 2);
    }
    int64_t i = map_find(map, key);
    LyricMapSlot* s = &map->slots[i];
    if (s->state == 1) {
        if (map->vals_are_refs) {
            lyric_retain((void*)(intptr_t)val);
            lyric_release((void*)(intptr_t)s->val);
        }
        s->val = val;
        return;
    }
    if (map->keys_are_strings) lyric_retain((void*)(intptr_t)key);
    if (map->vals_are_refs) lyric_retain((void*)(intptr_t)val);
    if (s->state == 0) map->used++;
    s->key = key;
    s->val = val;
    s->state = 1;
    map->len++;
}

int32_t lyric_map_get(LyricMap* map, int64_t key, int64_t* out_val) {
    if (map->cap == 0) return 0;
    int64_t i = map_find(map, key);
    if (map->slots[i].state != 1) return 0;
    *out_val = map->slots[i].val;
    return 1;
}

int32_t lyric_map_contains(LyricMap* map, int64_t key) {
    int64_t v;
    return lyric_map_get(map, key, &v);
}

int32_t lyric_map_remove(LyricMap* map, int64_t key) {
    if (map->cap == 0) return 0;
    int64_t i = map_find(map, key);
    LyricMapSlot* s = &map->slots[i];
    if (s->state != 1) return 0;
    if (map->keys_are_strings) lyric_release((void*)(intptr_t)s->key);
    if (map->vals_are_refs) lyric_release((void*)(intptr_t)s->val);
    s->state = 2;
    map->len--;
    return 1;
}

int64_t lyric_map_len(LyricMap* map) {
    return map->len;
}
