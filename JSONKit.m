//
//  JSONKit.m
//  http://github.com/johnezang/JSONKit
//  Licensed under the terms of the BSD License, as specified below.
//

/*
 Copyright (c) 2011, John Engelhart
 
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 
 * Neither the name of the Zang Industries nor the names of its
 contributors may be used to endorse or promote products derived from
 this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/


/*
  Acknowledgments:

  The bulk of the UTF8 / UTF32 conversion and verification comes
  from ConvertUTF.[hc].  It has been modified from the original sources.

  The original sources were obtained from http://www.unicode.org/.
  However, the web site no longer seems to host the files.  Instead,
  the Unicode FAQ http://www.unicode.org/faq//utf_bom.html#gen4
  points to International Components for Unicode (ICU)
  http://site.icu-project.org/ as an example of how to write a UTF
  converter.

  The decision to use the ConvertUTF.[ch] code was made to leverage
  "proven" code.  Hopefully the local modifications are bug free.

  The code in isValidCodePoint() is derived from the ICU code in
  utf.h for the macros U_IS_UNICODE_NONCHAR and U_IS_UNICODE_CHAR.

  From the original ConvertUTF.[ch]:

 * Copyright 2001-2004 Unicode, Inc.
 * 
 * Disclaimer
 * 
 * This source code is provided as is by Unicode, Inc. No claims are
 * made as to fitness for any particular purpose. No warranties of any
 * kind are expressed or implied. The recipient agrees to determine
 * applicability of information provided. If this file has been
 * purchased on magnetic or optical media from Unicode, Inc., the
 * sole remedy for any claim will be exchange of defective media
 * within 90 days of receipt.
 * 
 * Limitations on Rights to Redistribute This Code
 * 
 * Unicode, Inc. hereby grants the right to freely use the information
 * supplied in this file in the creation of products supporting the
 * Unicode Standard, and to make copies of this file in any form
 * for internal or external distribution as long as this notice
 * remains attached.

*/

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>
#include <sys/errno.h>
#include <math.h>
#include <limits.h>
#include <objc/runtime.h>

#import "JSONKit.h"

//#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFString.h>
#include <CoreFoundation/CFArray.h>
#include <CoreFoundation/CFDictionary.h>
#include <CoreFoundation/CFNumber.h>

//#import <Foundation/Foundation.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSData.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSException.h>
#import <Foundation/NSNull.h>
#import <Foundation/NSObjCRuntime.h>

#ifdef __OBJC_GC__
#error JSONKit does not support Objective-C Garbage Collection
#endif

#if (UINT_MAX < 0xffffffffU) || (INT_MIN < (-2147483647-1)) || (ULLONG_MAX < 0xffffffffffffffffULL) || (LLONG_MIN < (-0x7fffffffffffffffLL-1))
#error JSONKit requires the C 'int' and 'long long' types to be at least 32 and 64 bits respectively.
#endif

#ifdef JK_ENABLE_CF_TRANSFER_OWNERSHIP_CALLBACKS
#warning As of JSONKit v1.4, JK_ENABLE_CF_TRANSFER_OWNERSHIP_CALLBACKS is no longer required.  It is no longer a valid option.
#endif

// For DJB hash.
#define JK_HASH_INIT           (1402737925UL)

// Use __builtin_clz() instead of trailingBytesForUTF8[] table lookup.
#define JK_FAST_TRAILING_BYTES

// JK_CACHE_SLOTS must be a power of 2.  Default size is 1024 slots.
#define JK_CACHE_SLOTS_BITS    (10)
#define JK_CACHE_SLOTS         (1UL << JK_CACHE_SLOTS_BITS)
// JK_CACHE_PROBES is the number of probe attempts.
#define JK_CACHE_PROBES        (4UL)
// JK_INIT_CACHE_AGE must be (1 << AGE) - 1
#define JK_INIT_CACHE_AGE      (31)

// JK_TOKENBUFFER_SIZE is the default stack size for the temporary buffer used to hold "non-simple" strings (i.e., contains \ escapes)
#define JK_TOKENBUFFER_SIZE    (1024UL * 2UL)

// JK_STACK_OBJS is the default number of spaces reserved on the stack for temporarily storing pointers to Obj-C objects before they can be transferred to a NSArray / NSDictionary.
#define JK_STACK_OBJS          (1024UL * 1UL)

#define JK_JSONBUFFER_SIZE     (1024UL * 4UL)
#define JK_UTF8BUFFER_SIZE     (1024UL * 16UL)



#if       defined (__GNUC__) && (__GNUC__ >= 4)
#define JK_ATTRIBUTES(attr, ...)        __attribute__((attr, ##__VA_ARGS__))
#define JK_EXPECTED(cond, expect)       __builtin_expect((long)(cond), (expect))
#define JK_EXPECT_T(cond)               JK_EXPECTED(cond, 1U)
#define JK_EXPECT_F(cond)               JK_EXPECTED(cond, 0U)
#define JK_PREFETCH(ptr)                __builtin_prefetch(ptr)
#else  // defined (__GNUC__) && (__GNUC__ >= 4) 
#define JK_ATTRIBUTES(attr, ...)
#define JK_EXPECTED(cond, expect)       (cond)
#define JK_EXPECT_T(cond)               (cond)
#define JK_EXPECT_F(cond)               (cond)
#define JK_PREFETCH(ptr)
#endif // defined (__GNUC__) && (__GNUC__ >= 4) 

#define JK_STATIC_INLINE                         static __inline__ JK_ATTRIBUTES(always_inline)
#define JK_ALIGNED(arg)                                            JK_ATTRIBUTES(aligned(arg))
#define JK_UNUSED_ARG                                              JK_ATTRIBUTES(unused)
#define JK_WARN_UNUSED                                             JK_ATTRIBUTES(warn_unused_result)
#define JK_WARN_UNUSED_CONST                                       JK_ATTRIBUTES(warn_unused_result, const)
#define JK_WARN_UNUSED_PURE                                        JK_ATTRIBUTES(warn_unused_result, pure)
#define JK_WARN_UNUSED_SENTINEL                                    JK_ATTRIBUTES(warn_unused_result, sentinel)
#define JK_NONNULL_ARGS(arg, ...)                                  JK_ATTRIBUTES(nonnull(arg, ##__VA_ARGS__))
#define JK_WARN_UNUSED_NONNULL_ARGS(arg, ...)                      JK_ATTRIBUTES(warn_unused_result, nonnull(arg, ##__VA_ARGS__))
#define JK_WARN_UNUSED_CONST_NONNULL_ARGS(arg, ...)                JK_ATTRIBUTES(warn_unused_result, const, nonnull(arg, ##__VA_ARGS__))
#define JK_WARN_UNUSED_PURE_NONNULL_ARGS(arg, ...)                 JK_ATTRIBUTES(warn_unused_result, pure, nonnull(arg, ##__VA_ARGS__))

#if       defined (__GNUC__) && (__GNUC__ >= 4) && (__GNUC_MINOR__ >= 3)
#define JK_ALLOC_SIZE_NON_NULL_ARGS_WARN_UNUSED(as, nn, ...) JK_ATTRIBUTES(warn_unused_result, nonnull(nn, ##__VA_ARGS__), alloc_size(as))
#else  // defined (__GNUC__) && (__GNUC__ >= 4) && (__GNUC_MINOR__ >= 3)
#define JK_ALLOC_SIZE_NON_NULL_ARGS_WARN_UNUSED(as, nn, ...) JK_ATTRIBUTES(warn_unused_result, nonnull(nn, ##__VA_ARGS__))
#endif // defined (__GNUC__) && (__GNUC__ >= 4) && (__GNUC_MINOR__ >= 3)


@class JKArray, JKDictionaryEnumerator, JKDictionary;

enum {
  JSONNumberStateStart                 = 0,
  JSONNumberStateFinished              = 1,
  JSONNumberStateError                 = 2,
  JSONNumberStateWholeNumberStart      = 3,
  JSONNumberStateWholeNumberMinus      = 4,
  JSONNumberStateWholeNumberZero       = 5,
  JSONNumberStateWholeNumber           = 6,
  JSONNumberStatePeriod                = 7,
  JSONNumberStateFractionalNumberStart = 8,
  JSONNumberStateFractionalNumber      = 9,
  JSONNumberStateExponentStart         = 10,
  JSONNumberStateExponentPlusMinus     = 11,
  JSONNumberStateExponent              = 12,
};

enum {
  JSONStringStateStart                           = 0,
  JSONStringStateParsing                         = 1,
  JSONStringStateFinished                        = 2,
  JSONStringStateError                           = 3,
  JSONStringStateEscape                          = 4,
  JSONStringStateEscapedUnicode1                 = 5,
  JSONStringStateEscapedUnicode2                 = 6,
  JSONStringStateEscapedUnicode3                 = 7,
  JSONStringStateEscapedUnicode4                 = 8,
  JSONStringStateEscapedUnicodeSurrogate1        = 9,
  JSONStringStateEscapedUnicodeSurrogate2        = 10,
  JSONStringStateEscapedUnicodeSurrogate3        = 11,
  JSONStringStateEscapedUnicodeSurrogate4        = 12,
  JSONStringStateEscapedNeedEscapeForSurrogate   = 13,
  JSONStringStateEscapedNeedEscapedUForSurrogate = 14,
};

enum {
  JKParseAcceptValue      = (1 << 0),
  JKParseAcceptComma      = (1 << 1),
  JKParseAcceptEnd        = (1 << 2),
  JKParseAcceptValueOrEnd = (JKParseAcceptValue | JKParseAcceptEnd),
  JKParseAcceptCommaOrEnd = (JKParseAcceptComma | JKParseAcceptEnd),
};

enum {
  JKClassUnknown    = 0,
  JKClassString     = 1,
  JKClassNumber     = 2,
  JKClassArray      = 3,
  JKClassDictionary = 4,
  JKClassNull       = 5,
};

enum {
  JKManagedBufferOnStack        = 1,
  JKManagedBufferOnHeap         = 2,
  JKManagedBufferLocationMask   = (0x3),
  JKManagedBufferLocationShift  = (0),
  
  JKManagedBufferMustFree       = (1 << 2),
};
typedef JKFlags JKManagedBufferFlags;

enum {
  JKObjectStackOnStack        = 1,
  JKObjectStackOnHeap         = 2,
  JKObjectStackLocationMask   = (0x3),
  JKObjectStackLocationShift  = (0),
  
  JKObjectStackMustFree       = (1 << 2),
};
typedef JKFlags JKObjectStackFlags;

enum {
  JKTokenTypeInvalid     = 0,
  JKTokenTypeNumber      = 1,
  JKTokenTypeString      = 2,
  JKTokenTypeObjectBegin = 3,
  JKTokenTypeObjectEnd   = 4,
  JKTokenTypeArrayBegin  = 5,
  JKTokenTypeArrayEnd    = 6,
  JKTokenTypeSeparator   = 7,
  JKTokenTypeComma       = 8,
  JKTokenTypeTrue        = 9,
  JKTokenTypeFalse       = 10,
  JKTokenTypeNull        = 11,
  JKTokenTypeWhiteSpace  = 12,
};
typedef NSUInteger JKTokenType;

// These are prime numbers to assist with hash slot probing.
enum {
  JKValueTypeNone             = 0,
  JKValueTypeString           = 5,
  JKValueTypeLongLong         = 7,
  JKValueTypeUnsignedLongLong = 11,
  JKValueTypeDouble           = 13,
};
typedef NSUInteger JKValueType;

enum {
  JKEncodeAsData   = 1,
  JKEncodeAsString = 2,
};
typedef NSUInteger JKEncodeAsType;

typedef NSUInteger JKHash;

typedef id (*NSNumberAllocImp)(id object, SEL selector);
typedef id (*NSNumberInitWithUnsignedLongLongImp)(id object, SEL selector, unsigned long long value);

typedef struct JKTokenCacheItem  JKTokenCacheItem;
typedef struct JKTokenCache      JKTokenCache;
typedef struct JKTokenValue      JKTokenValue;
typedef struct JKParseToken      JKParseToken;
typedef struct JKPtrRange        JKPtrRange;
typedef struct JKObjectStack     JKObjectStack;
typedef struct JKBuffer          JKBuffer;
typedef struct JKConstBuffer     JKConstBuffer;
typedef struct JKConstPtrRange   JKConstPtrRange;
typedef struct JKRange           JKRange;
typedef struct JKManagedBuffer   JKManagedBuffer;
typedef struct JKFastClassLookup JKFastClassLookup;
typedef struct JKEncodeState     JKEncodeState;
typedef struct JKObjCImpCache    JKObjCImpCache;
typedef struct JKHashTableEntry  JKHashTableEntry;


struct JKPtrRange {
  unsigned char *ptr;
  size_t         length;
};

struct JKConstPtrRange {
  const unsigned char *ptr;
  size_t               length;
};

struct JKRange {
  size_t location, length;
};

struct JKManagedBuffer {
  JKPtrRange           bytes;
  JKManagedBufferFlags flags;
  size_t               roundSizeUpToMultipleOf;
};

struct JKObjectStack {
  void               **objects, **keys;
  CFHashCode          *cfHashes;
  size_t               count, index, roundSizeUpToMultipleOf;
  JKObjectStackFlags   flags;
};

struct JKBuffer {
  JKPtrRange bytes;
};

struct JKConstBuffer {
  JKConstPtrRange bytes;
};

struct JKTokenValue {
  JKConstPtrRange   ptrRange;
  JKHash            hash;
  JKTokenCacheItem *cacheItem;
  JKValueType       type;
  union {
    long long          longLongValue;
    unsigned long long unsignedLongLongValue;
    double             doubleValue;
  } number;
};

struct JKParseToken {
  JKConstPtrRange tokenPtrRange;
  JKTokenType     type;
  JKTokenValue    value;
  JKManagedBuffer tokenBuffer;
};

struct JKTokenCacheItem {
  void          *object;
  JKHash         hash;
  CFHashCode     cfHash;
  size_t         size;
  unsigned char *bytes;
  JKValueType    type;
  unsigned char  age;
};

struct JKTokenCache {
  JKTokenCacheItem *items;
  size_t            count;
  unsigned int      prng_lcg;
};

struct JKObjCImpCache {
  Class                               NSNumberClass;
  NSNumberAllocImp                    NSNumberAlloc;
  NSNumberInitWithUnsignedLongLongImp NSNumberInitWithUnsignedLongLong;
};

struct JKParseState {
  JKParseOptionFlags  parseOptionFlags;
  JKConstBuffer       stringBuffer;
  size_t              atIndex, lineNumber, lineStartIndex;
  size_t              prev_atIndex, prev_lineNumber, prev_lineStartIndex;
  int                 errorIsPrev;
  JKParseToken        token;
  JKObjectStack       objectStack;
  JKTokenCache        cache;
  JKObjCImpCache      objCImpCache;
  NSError            *error;
};

struct JKFastClassLookup {
  void *stringClass;
  void *numberClass;
  void *arrayClass;
  void *dictionaryClass;
  void *nullClass;
};

struct JKEncodeState {
  JKManagedBuffer         utf8ConversionBuffer;
  JKManagedBuffer         stringBuffer;
  size_t                  atIndex;
  JKFastClassLookup       fastClassLookup;
  JKSerializeOptionFlags  serializeOptionFlags;
  NSError                *error;
};

struct JKHashTableEntry {
  NSUInteger keyHash;
  id key, object;
};


typedef uint32_t UTF32; /* at least 32 bits */
typedef uint16_t UTF16; /* at least 16 bits */
typedef uint8_t  UTF8;  /* typically 8 bits */

typedef enum {
  conversionOK,           /* conversion successful */
  sourceExhausted,        /* partial character in source, but hit end */
  targetExhausted,        /* insuff. room in target for conversion */
  sourceIllegal           /* source sequence is illegal/malformed */
} ConversionResult;

#define UNI_REPLACEMENT_CHAR (UTF32)0x0000FFFD
#define UNI_MAX_BMP          (UTF32)0x0000FFFF
#define UNI_MAX_UTF16        (UTF32)0x0010FFFF
#define UNI_MAX_UTF32        (UTF32)0x7FFFFFFF
#define UNI_MAX_LEGAL_UTF32  (UTF32)0x0010FFFF
#define UNI_SUR_HIGH_START   (UTF32)0xD800
#define UNI_SUR_HIGH_END     (UTF32)0xDBFF
#define UNI_SUR_LOW_START    (UTF32)0xDC00
#define UNI_SUR_LOW_END      (UTF32)0xDFFF


#if !defined(JK_FAST_TRAILING_BYTES)
static const char trailingBytesForUTF8[256] = {
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2, 3,3,3,3,3,3,3,3,4,4,4,4,5,5,5,5
};
#endif

static const UTF32 offsetsFromUTF8[6] = { 0x00000000UL, 0x00003080UL, 0x000E2080UL, 0x03C82080UL, 0xFA082080UL, 0x82082080UL };
static const UTF8  firstByteMark[7]   = { 0x00, 0x00, 0xC0, 0xE0, 0xF0, 0xF8, 0xFC };

#define JK_AT_STRING_PTR(x)  (&((x)->stringBuffer.bytes.ptr[(x)->atIndex]))
#define JK_END_STRING_PTR(x) (&((x)->stringBuffer.bytes.ptr[(x)->stringBuffer.bytes.length]))


static JKArray *_JKArrayCreate(id *objects, NSUInteger count);

static JKDictionary     *_JKDictionaryCreate(id *keys, NSUInteger *keyHashes, id *objects, NSUInteger count);
static JKHashTableEntry *_JKDictionaryHashEntry(JKDictionary *dictionary);
static NSUInteger        _JKDictionaryCapacity(JKDictionary *dictionary);
static void              _JKDictionaryAddObject(JKDictionary *dictionary, NSUInteger keyHash, id key, id object);

static void jk_managedBuffer_release(JKManagedBuffer *managedBuffer);
static void jk_managedBuffer_setToStackBuffer(JKManagedBuffer *managedBuffer, unsigned char *ptr, size_t length);
static unsigned char *jk_managedBuffer_resize(JKManagedBuffer *managedBuffer, size_t newSize);
static void jk_objectStack_release(JKObjectStack *objectStack);
static void jk_objectStack_setToStackBuffer(JKObjectStack *objectStack, void **objects, void **keys, CFHashCode *cfHashes, size_t count);
static int  jk_objectStack_resize(JKObjectStack *objectStack, size_t newCount);

static void   jk_error(JKParseState *parseState, NSString *format, ...);
static int    jk_parse_string(JKParseState *parseState);
static int    jk_parse_number(JKParseState *parseState);
static size_t jk_parse_is_newline(JKParseState *parseState, const unsigned char *atCharacterPtr);
JK_STATIC_INLINE int jk_parse_skip_newline(JKParseState *parseState);
JK_STATIC_INLINE void jk_parse_skip_whitespace(JKParseState *parseState);
static int    jk_parse_next_token(JKParseState *parseState);
static void   jk_error_parse_accept_or3(JKParseState *parseState, int state, NSString *or1String, NSString *or2String, NSString *or3String);
static void  *jk_create_dictionary(JKParseState *parseState, size_t startingObjectIndex);
static void  *jk_parse_dictionary(JKParseState *parseState);
static void  *jk_parse_array(JKParseState *parseState);
static void  *jk_object_for_token(JKParseState *parseState);
static void  *jk_cachedObjects(JKParseState *parseState);
JK_STATIC_INLINE void jk_cache_age(JKParseState *parseState);
JK_STATIC_INLINE void jk_set_parsed_token(JKParseState *parseState, const unsigned char *ptr, size_t length, JKTokenType type, size_t advanceBy);


static void jk_encode_error(JKEncodeState *encodeState, NSString *format, ...);
static int jk_encode_printf(JKEncodeState *encodeState, const char *format, ...);
static int jk_encode_write(JKEncodeState *encodeState, const char *format);
static int jk_encode_write1(JKEncodeState *encodeState, const char *format);
static int jk_encode_writen(JKEncodeState *encodeState, const char *format, size_t length);
static int jk_encode_add_atom_to_buffer(JKEncodeState *encodeState, void *objectPtr);
static id jk_encode(void *object, JKSerializeOptionFlags optionFlags, JKEncodeAsType encodeAs, NSError **error);


JK_STATIC_INLINE size_t jk_min(size_t a, size_t b);
JK_STATIC_INLINE size_t jk_max(size_t a, size_t b);
JK_STATIC_INLINE JKHash calculateHash(JKHash currentHash, unsigned char c);


@interface JKArray : NSArray <NSCopying, NSMutableCopying, NSFastEnumeration> {
  id         *objects;
  NSUInteger  count;
}
@end

@implementation JKArray

static Class _JKArrayClass         = NULL;
static size_t _JKArrayInstanceSize = 0UL;

+ (void)load
{
  _JKArrayClass        = [JKArray class];
  _JKArrayInstanceSize = class_getInstanceSize(_JKArrayClass);
}

+ (id)allocWithZone:(NSZone *)zone
{
#pragma unused(zone)
  [NSException raise:NSInvalidArgumentException format:@"*** - [%@ %@]: The %@ class is private to JSONKit and should not be used in this fashion.", NSStringFromClass([self class]), NSStringFromSelector(_cmd), NSStringFromClass([self class])];
  return(NULL);
}

static JKArray *_JKArrayCreate(id *objects, NSUInteger count) {
  NSCParameterAssert((objects != NULL) && (_JKArrayClass != NULL) && (_JKArrayInstanceSize > 0UL));
  JKArray *array = NULL;
  if(JK_EXPECT_T((array = (JKArray *)calloc(1UL, _JKArrayInstanceSize)) != NULL)) {
    array->isa = _JKArrayClass;
    if(JK_EXPECT_F((array = [array init]) == NULL)) { return(NULL); }

    array->count = count;
    if(JK_EXPECT_F((array->objects = (id *)malloc(sizeof(id) * array->count)) == NULL)) { [array autorelease]; return(NULL); }
    memcpy(array->objects, objects, array->count * sizeof(id));
  }
  return(array);
}

- (void)dealloc
{
  if(JK_EXPECT_T(objects != NULL)) {
    NSUInteger atObject = 0UL;
    for(atObject = 0UL; atObject < count; atObject++) { if(JK_EXPECT_T(objects[atObject] != NULL)) { CFRelease(objects[atObject]); objects[atObject] = NULL; } }
    free(objects); objects = NULL;
  }
  
  [super dealloc];
}

- (NSUInteger)count
{
  return(count);
}

- (void)getObjects:(id *)objectsPtr range:(NSRange)range
{
  NSParameterAssert(objects != NULL);
  if((range.location > count) || (NSMaxRange(range) > count)) { [NSException raise:NSRangeException format:@"*** -[%@ %@]: index (%lu) beyond bounds (%lu)", NSStringFromClass([self class]), NSStringFromSelector(_cmd), NSMaxRange(range), count]; }
  memcpy(objectsPtr, objects + range.location, range.length * sizeof(id));
}

- (id)objectAtIndex:(NSUInteger)objectIndex
{
  if(objectIndex >= count) { [NSException raise:NSRangeException format:@"*** -[%@ %@]: index (%lu) beyond bounds (%lu)", NSStringFromClass([self class]), NSStringFromSelector(_cmd), objectIndex, count]; }
  NSParameterAssert((objects != NULL) && (objects[objectIndex] != NULL));
  return(objects[objectIndex]);
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id *)stackbuf count:(NSUInteger)len
{
  NSParameterAssert(objects != NULL);
  if(JK_EXPECT_F(state->state == 0UL))   { state->mutationsPtr = &state->extra[0]; state->itemsPtr = stackbuf; }
  if(JK_EXPECT_F(state->state >= count)) { return(0UL); }
  
  NSUInteger enumeratedCount  = 0UL;
  while(JK_EXPECT_T(enumeratedCount < len) && JK_EXPECT_T(state->state < count)) { NSParameterAssert(objects[state->state] != NULL); stackbuf[enumeratedCount++] = objects[state->state++]; }
  
  return(enumeratedCount);
}

- (id)copyWithZone:(NSZone *)zone
{
#pragma unused(zone)
  return([self retain]);
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
  NSParameterAssert(objects != NULL);
  return([[NSMutableArray allocWithZone:zone] initWithObjects:objects count:count]);
}

@end



@interface JKDictionaryEnumerator : NSEnumerator {
  id         collection;
  NSUInteger nextObject;
}

- (id)initWithJKDictionary:(JKDictionary *)initDictionary;
- (NSArray *)allObjects;
- (id)nextObject;

@end

@implementation JKDictionaryEnumerator

- (id)initWithJKDictionary:(JKDictionary *)initDictionary
{
  NSParameterAssert(initDictionary != NULL);
  if((self = [super init]) == NULL) { return(NULL); }
  if((collection = (id)CFRetain(initDictionary)) == NULL) { [self autorelease]; return(NULL); }
  return(self);
}

- (void)dealloc
{
  if(collection != NULL) { CFRelease(collection); collection = NULL; }
  [super dealloc];
}

- (NSArray *)allObjects
{
  NSParameterAssert(collection != NULL);
  NSUInteger count = [collection count], atObject = 0UL;
  id         objects[count];

  while((objects[atObject] = [self nextObject]) != NULL) { NSParameterAssert(atObject < count); atObject++; }

  return([NSArray arrayWithObjects:objects count:atObject]);
}

- (id)nextObject
{
  NSParameterAssert((collection != NULL) && (_JKDictionaryHashEntry(collection) != NULL));
  JKHashTableEntry *entry        = _JKDictionaryHashEntry(collection);
  NSUInteger        capacity     = _JKDictionaryCapacity(collection);
  id                returnObject = NULL;

  if(entry != NULL) { while((nextObject < capacity) && ((returnObject = entry[nextObject++].key) == NULL)) { /* ... */ } }
  
  return(returnObject);
}

@end

@interface JKDictionary : NSDictionary <NSCopying, NSMutableCopying, NSFastEnumeration> {
  NSUInteger count, capacity;
  JKHashTableEntry *entry;
}
@end

@implementation JKDictionary

// These values are taken from CF-550 CFBasicHash.m.  As a bonus, they allign very well with our JKHashTableEntry struct too.
static const NSUInteger jk_dictionaryCapacities[] = {
  0UL, 3UL, 7UL, 13UL, 23UL, 41UL, 71UL, 127UL, 191UL, 251UL, 383UL, 631UL, 1087UL, 1723UL,
  2803UL, 4523UL, 7351UL, 11959UL, 19447UL, 31231UL, 50683UL, 81919UL, 132607UL,
  214519UL, 346607UL, 561109UL, 907759UL, 1468927UL, 2376191UL, 3845119UL,
  6221311UL, 10066421UL, 16287743UL, 26354171UL, 42641881UL, 68996069UL,
  111638519UL, 180634607UL, 292272623UL, 472907251UL
};

static Class  _JKDictionaryClass        = NULL;
static size_t _JKDictionaryInstanceSize = 0UL;

+ (void)load
{
  _JKDictionaryClass        = [JKDictionary class];
  _JKDictionaryInstanceSize = class_getInstanceSize(_JKDictionaryClass);
}

+ (id)allocWithZone:(NSZone *)zone
{
#pragma unused(zone)
  [NSException raise:NSInvalidArgumentException format:@"*** - [%@ %@]: The %@ class is private to JSONKit and should not be used in this fashion.", NSStringFromClass([self class]), NSStringFromSelector(_cmd), NSStringFromClass([self class])];
  return(NULL);
}

static JKDictionary *_JKDictionaryCreate(id *keys, NSUInteger *keyHashes, id *objects, NSUInteger count) {
  NSCParameterAssert((keys != NULL) && (keyHashes != NULL) && (objects != NULL) && (_JKDictionaryClass != NULL) && (_JKDictionaryInstanceSize > 0UL));
  JKDictionary *dictionary = NULL;
  if(JK_EXPECT_T((dictionary = (JKDictionary *)calloc(1UL, _JKDictionaryInstanceSize)) != NULL)) {
    dictionary->isa = _JKDictionaryClass;
    if(JK_EXPECT_F((dictionary = [dictionary init]) == NULL)) { return(NULL); }
    
    NSUInteger bottom = 0UL, top = sizeof(jk_dictionaryCapacities) / sizeof(NSUInteger), mid = 0UL, tableSize = lround(floor((count + 0UL) * 1.33));
    while(top > bottom) { mid = (top + bottom) / 2UL; if(jk_dictionaryCapacities[mid] < tableSize) { bottom = mid + 1UL; } else { top = mid; } }
    
    dictionary->capacity = jk_dictionaryCapacities[bottom];
    dictionary->count    = 0UL;
    
    if(JK_EXPECT_F((dictionary->entry = (JKHashTableEntry *)calloc(1UL, sizeof(JKHashTableEntry) * dictionary->capacity)) == NULL)) { [dictionary autorelease]; return(NULL); }

    NSUInteger idx = 0UL;
    for(idx = 0UL; idx < count; idx++) { _JKDictionaryAddObject(dictionary, keyHashes[idx], keys[idx], objects[idx]); }
  }
  return(dictionary);
}

- (void)dealloc
{
  if(JK_EXPECT_T(entry != NULL)) {
    NSUInteger atEntry = 0UL;
    for(atEntry = 0UL; atEntry < capacity; atEntry++) {
      if(JK_EXPECT_T(entry[atEntry].key    != NULL)) { CFRelease(entry[atEntry].key);    entry[atEntry].key    = NULL; }
      if(JK_EXPECT_T(entry[atEntry].object != NULL)) { CFRelease(entry[atEntry].object); entry[atEntry].object = NULL; }
    }
  
    free(entry); entry = NULL;
  }

  [super dealloc];
}

static JKHashTableEntry *_JKDictionaryHashEntry(JKDictionary *dictionary) {
  NSCParameterAssert(dictionary != NULL);
  return(dictionary->entry);
}

static NSUInteger _JKDictionaryCapacity(JKDictionary *dictionary) {
  NSCParameterAssert(dictionary != NULL);
  return(dictionary->capacity);
}

static void _JKDictionaryAddObject(JKDictionary *dictionary, NSUInteger keyHash, id key, id object) {
  NSCParameterAssert((dictionary != NULL) && (key != NULL) && (object != NULL) && (dictionary->count < dictionary->capacity) && (dictionary->entry != NULL));
  NSUInteger keyEntry = keyHash % dictionary->capacity, idx = 0UL;
  for(idx = 0UL; idx < dictionary->capacity; idx++) {
    NSUInteger entryIdx = (keyEntry + idx) % dictionary->capacity;
    JKHashTableEntry *atEntry = &dictionary->entry[entryIdx];
    if(JK_EXPECT_F(atEntry->keyHash == keyHash) && JK_EXPECT_T(atEntry->key != NULL) && (JK_EXPECT_F(key == atEntry->key) || JK_EXPECT_F(CFEqual(atEntry->key, key)))) {
      CFRelease(atEntry->key);    atEntry->key    = NULL;
      CFRelease(atEntry->object); atEntry->object = NULL;
      atEntry->keyHash = 0UL;
      dictionary->count--;
    }
    if(JK_EXPECT_T(atEntry->key == NULL)) { atEntry->key = key; atEntry->object = object; atEntry->keyHash = keyHash; dictionary->count++; return; }
  }

  // We should never get here.  If we do, we -release the key / object because it's our responsibility.
  CFRelease(key);
  CFRelease(object);
}

- (NSUInteger)count
{
  return(count);
}

- (id)objectForKey:(id)aKey
{
  NSParameterAssert((entry != NULL) && (count <= capacity));
  NSUInteger keyHash      = CFHash(aKey), keyEntry = (keyHash % capacity), idx = 0UL;
  id         returnObject = NULL;
  for(idx = 0UL; idx < capacity; idx++) {
    JKHashTableEntry *atEntry = &entry[(keyEntry + idx) % capacity];
    if(JK_EXPECT_T(atEntry->keyHash == keyHash) && JK_EXPECT_T(atEntry->key != NULL) && ((atEntry->key == aKey) || CFEqual(atEntry->key, aKey))) { NSParameterAssert(atEntry->object != NULL); returnObject = atEntry->object; break; }
  }
  return(returnObject);
}

- (void)getObjects:(id *)objects andKeys:(id *)keys
{
  NSParameterAssert((entry != NULL) && (count <= capacity));
  NSUInteger idx = 0UL, atEntry = 0UL;
  for(atEntry = 0UL; atEntry < capacity; atEntry++) {
    if(JK_EXPECT_T(entry[atEntry].key != NULL)) { NSParameterAssert((entry[atEntry].object != NULL) && (idx < count)); if(JK_EXPECT_T(keys != NULL)) { keys[idx] = entry[atEntry].key; } if(JK_EXPECT_T(objects != NULL)) { objects[idx] = entry[atEntry].object; } idx++; }
  }
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id *)stackbuf count:(NSUInteger)len
{
  NSParameterAssert((entry != NULL) && (count <= capacity));
  if(JK_EXPECT_F(state->state == 0UL))      { state->mutationsPtr = &state->extra[0]; state->itemsPtr = stackbuf; }
  if(JK_EXPECT_F(state->state >= capacity)) { return(0UL); }
  
  NSUInteger enumeratedCount  = 0UL;
  while(JK_EXPECT_T(enumeratedCount < len) && JK_EXPECT_T(state->state < capacity)) { if(JK_EXPECT_T(entry[state->state].key != NULL)) { stackbuf[enumeratedCount++] = entry[state->state].key; } state->state++; }
    
  return(enumeratedCount);
}

- (NSEnumerator *)keyEnumerator
{
  return([[[JKDictionaryEnumerator alloc] initWithJKDictionary:self] autorelease]);
}

- (id)copyWithZone:(NSZone *)zone
{
#pragma unused(zone)
  return([self retain]);
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
  NSParameterAssert((entry != NULL) && (count <= capacity));
  id stackKeys[count], stackObjects[count];
  NSUInteger idx = 0UL, stackIdx = 0UL;
  for(idx = 0UL; idx < capacity; idx++) { if(entry[idx].key != NULL) { NSParameterAssert(stackIdx < count); stackKeys[stackIdx] = entry[idx].key; stackObjects[stackIdx++] = entry[idx].object; } }
  NSParameterAssert(stackIdx == count);
  return([[NSMutableDictionary allocWithZone:zone] initWithObjects:stackObjects forKeys:stackKeys count:stackIdx]);
}

@end


JK_STATIC_INLINE size_t jk_min(size_t a, size_t b) { return((a < b) ? a : b); }
JK_STATIC_INLINE size_t jk_max(size_t a, size_t b) { return((a > b) ? a : b); }

JK_STATIC_INLINE JKHash calculateHash(JKHash currentHash, unsigned char c) { return(((currentHash << 5) + currentHash) + c); }

static void jk_error(JKParseState *parseState, NSString *format, ...) {
  NSCParameterAssert((parseState != NULL) && (format != NULL));

  va_list varArgsList;
  va_start(varArgsList, format);
  NSString *formatString = [[[NSString alloc] initWithFormat:format arguments:varArgsList] autorelease];
  va_end(varArgsList);

#if 0
  const unsigned char *lineStart      = parseState->stringBuffer.bytes.ptr + parseState->lineStartIndex;
  const unsigned char *lineEnd        = lineStart;
  const unsigned char *atCharacterPtr = NULL;

  for(atCharacterPtr = lineStart; atCharacterPtr < JK_END_STRING_PTR(parseState); atCharacterPtr++) { lineEnd = atCharacterPtr; if(jk_parse_is_newline(parseState, atCharacterPtr)) { break; } }

  NSString *lineString = @"", *carretString = @"";
  if(lineStart < JK_END_STRING_PTR(parseState)) {
    lineString   = [[[NSString alloc] initWithBytes:lineStart length:(lineEnd - lineStart) encoding:NSUTF8StringEncoding] autorelease];
    carretString = [NSString stringWithFormat:@"%*.*s^", (int)(parseState->atIndex - parseState->lineStartIndex), (int)(parseState->atIndex - parseState->lineStartIndex), " "];
  }
#endif

  if(parseState->error == NULL) {
    parseState->error = [NSError errorWithDomain:@"JKErrorDomain" code:-1L userInfo:
                                   [NSDictionary dictionaryWithObjectsAndKeys:
                                                                              formatString,                                             NSLocalizedDescriptionKey,
                                                                              [NSNumber numberWithUnsignedLong:parseState->atIndex],    @"JKAtIndexKey",
                                                                              [NSNumber numberWithUnsignedLong:parseState->lineNumber], @"JKLineNumberKey",
                                                 //lineString,   @"JKErrorLine0Key",
                                                 //carretString, @"JKErrorLine1Key",
                                                                              NULL]];
  }
}


static void jk_managedBuffer_release(JKManagedBuffer *managedBuffer) {
  if((managedBuffer->flags & JKManagedBufferMustFree)) {
    if(managedBuffer->bytes.ptr != NULL) { free(managedBuffer->bytes.ptr); managedBuffer->bytes.ptr = NULL; }
    managedBuffer->flags &= ~JKManagedBufferMustFree;
  }

  managedBuffer->bytes.ptr     = NULL;
  managedBuffer->bytes.length  = 0UL;
  managedBuffer->flags        &= ~JKManagedBufferLocationMask;
}

static void jk_managedBuffer_setToStackBuffer(JKManagedBuffer *managedBuffer, unsigned char *ptr, size_t length) {
  jk_managedBuffer_release(managedBuffer);
  managedBuffer->bytes.ptr     = ptr;
  managedBuffer->bytes.length  = length;
  managedBuffer->flags         = (managedBuffer->flags & ~JKManagedBufferLocationMask) | JKManagedBufferOnStack;
}

static unsigned char *jk_managedBuffer_resize(JKManagedBuffer *managedBuffer, size_t newSize) {
  size_t roundedUpNewSize = newSize;

  if(managedBuffer->roundSizeUpToMultipleOf > 0UL) { roundedUpNewSize = newSize + ((managedBuffer->roundSizeUpToMultipleOf - (newSize % managedBuffer->roundSizeUpToMultipleOf)) % managedBuffer->roundSizeUpToMultipleOf); }

  if((roundedUpNewSize != managedBuffer->bytes.length) && (roundedUpNewSize > managedBuffer->bytes.length)) {
    if((managedBuffer->flags & JKManagedBufferLocationMask) == JKManagedBufferOnStack) {
      NSCParameterAssert((managedBuffer->flags & JKManagedBufferMustFree) == 0);
      unsigned char *newBuffer = NULL, *oldBuffer = managedBuffer->bytes.ptr;
      
      if((newBuffer = (unsigned char *)malloc(roundedUpNewSize)) == NULL) { return(NULL); }
      memcpy(newBuffer, oldBuffer, jk_min(managedBuffer->bytes.length, roundedUpNewSize));
      managedBuffer->flags        = (managedBuffer->flags & ~JKManagedBufferLocationMask) | (JKManagedBufferOnHeap | JKManagedBufferMustFree);
      managedBuffer->bytes.ptr    = newBuffer;
      managedBuffer->bytes.length = roundedUpNewSize;
    } else {
      NSCParameterAssert(((managedBuffer->flags & JKManagedBufferMustFree) != 0) && ((managedBuffer->flags & JKManagedBufferLocationMask) == JKManagedBufferOnHeap));
      if((managedBuffer->bytes.ptr = (unsigned char *)reallocf(managedBuffer->bytes.ptr, roundedUpNewSize)) == NULL) { return(NULL); }
      managedBuffer->bytes.length = roundedUpNewSize;
    }
  }

  return(managedBuffer->bytes.ptr);
}



static void jk_objectStack_release(JKObjectStack *objectStack) {
  NSCParameterAssert(objectStack != NULL);

  NSCParameterAssert(objectStack->index <= objectStack->count);
  size_t atIndex = 0UL;
  for(atIndex = 0UL; atIndex < objectStack->index; atIndex++) {
    if(objectStack->objects[atIndex] != NULL) { CFRelease(objectStack->objects[atIndex]); objectStack->objects[atIndex] = NULL; }
    if(objectStack->keys[atIndex]    != NULL) { CFRelease(objectStack->keys[atIndex]);    objectStack->keys[atIndex]    = NULL; }
  }
  objectStack->index = 0UL;

  if(objectStack->flags & JKObjectStackMustFree) {
    NSCParameterAssert((objectStack->flags & JKObjectStackLocationMask) == JKObjectStackOnHeap);
    if(objectStack->objects  != NULL) { free(objectStack->objects);  objectStack->objects  = NULL; }
    if(objectStack->keys     != NULL) { free(objectStack->keys);     objectStack->keys     = NULL; }
    if(objectStack->cfHashes != NULL) { free(objectStack->cfHashes); objectStack->cfHashes = NULL; }
    objectStack->flags &= ~JKObjectStackMustFree;
  }

  objectStack->objects  = NULL;
  objectStack->keys     = NULL;
  objectStack->cfHashes = NULL;

  objectStack->count    = 0UL;
  objectStack->flags   &= ~JKObjectStackLocationMask;
}

static void jk_objectStack_setToStackBuffer(JKObjectStack *objectStack, void **objects, void **keys, CFHashCode *cfHashes, size_t count) {
  NSCParameterAssert((objectStack != NULL) && (objects != NULL) && (keys != NULL) && (cfHashes != NULL) && (count > 0UL));
  jk_objectStack_release(objectStack);
  objectStack->objects  = objects;
  objectStack->keys     = keys;
  objectStack->cfHashes = cfHashes;
  objectStack->count    = count;
  objectStack->flags    = (objectStack->flags & ~JKObjectStackLocationMask) | JKObjectStackOnStack;
#ifndef NS_BLOCK_ASSERTIONS
  size_t idx;
  for(idx = 0UL; idx < objectStack->count; idx++) { objectStack->objects[idx] = NULL; objectStack->keys[idx] = NULL; objectStack->cfHashes[idx] = 0UL; }
#endif
}

static int jk_objectStack_resize(JKObjectStack *objectStack, size_t newCount) {
  size_t roundedUpNewCount = newCount;
  int    returnCode = 0;

  void       **newObjects  = NULL, **newKeys = NULL;
  CFHashCode  *newCFHashes = NULL;

  if(objectStack->roundSizeUpToMultipleOf > 0UL) { roundedUpNewCount = newCount + ((objectStack->roundSizeUpToMultipleOf - (newCount % objectStack->roundSizeUpToMultipleOf)) % objectStack->roundSizeUpToMultipleOf); }

  if((roundedUpNewCount != objectStack->count) && (roundedUpNewCount > objectStack->count)) {
    if((objectStack->flags & JKObjectStackLocationMask) == JKObjectStackOnStack) {
      NSCParameterAssert((objectStack->flags & JKObjectStackMustFree) == 0);

      if((newObjects  = (void **     )calloc(1UL, roundedUpNewCount * sizeof(void *    ))) == NULL) { returnCode = 1; goto errorExit; }
      memcpy(newObjects, objectStack->objects,   jk_min(objectStack->count, roundedUpNewCount) * sizeof(void *));
      if((newKeys     = (void **     )calloc(1UL, roundedUpNewCount * sizeof(void *    ))) == NULL) { returnCode = 1; goto errorExit; }
      memcpy(newKeys,     objectStack->keys,     jk_min(objectStack->count, roundedUpNewCount) * sizeof(void *));

      if((newCFHashes = (CFHashCode *)calloc(1UL, roundedUpNewCount * sizeof(CFHashCode))) == NULL) { returnCode = 1; goto errorExit; }
      memcpy(newCFHashes, objectStack->cfHashes, jk_min(objectStack->count, roundedUpNewCount) * sizeof(CFHashCode));

      objectStack->flags    = (objectStack->flags & ~JKObjectStackLocationMask) | (JKObjectStackOnHeap | JKObjectStackMustFree);
      objectStack->objects  = newObjects;  newObjects  = NULL;
      objectStack->keys     = newKeys;     newKeys     = NULL;
      objectStack->cfHashes = newCFHashes; newCFHashes = NULL;
      objectStack->count    = roundedUpNewCount;
    } else {
      NSCParameterAssert(((objectStack->flags & JKObjectStackMustFree) != 0) && ((objectStack->flags & JKObjectStackLocationMask) == JKObjectStackOnHeap));
      if((newObjects  = (void  **    )realloc(objectStack->objects,  roundedUpNewCount * sizeof(void *    ))) != NULL) { objectStack->objects  = newObjects;  newObjects  = NULL; } else { returnCode = 1; goto errorExit; }
      if((newKeys     = (void  **    )realloc(objectStack->keys,     roundedUpNewCount * sizeof(void *    ))) != NULL) { objectStack->keys     = newKeys;     newKeys     = NULL; } else { returnCode = 1; goto errorExit; }
      if((newCFHashes = (CFHashCode *)realloc(objectStack->cfHashes, roundedUpNewCount * sizeof(CFHashCode))) != NULL) { objectStack->cfHashes = newCFHashes; newCFHashes = NULL; } else { returnCode = 1; goto errorExit; }

#ifndef NS_BLOCK_ASSERTIONS
      size_t idx;
      for(idx = objectStack->count; idx < roundedUpNewCount; idx++) { objectStack->objects[idx] = NULL; objectStack->keys[idx] = NULL; objectStack->cfHashes[idx] = 0UL; }
#endif
      objectStack->count = roundedUpNewCount;
    }
  }

 errorExit:
  if(newObjects  != NULL) { free(newObjects);  newObjects  = NULL; }
  if(newKeys     != NULL) { free(newKeys);     newKeys     = NULL; }
  if(newCFHashes != NULL) { free(newCFHashes); newCFHashes = NULL; }

  return(returnCode);
}


JK_STATIC_INLINE ConversionResult isValidCodePoint(UTF32 *u32CodePoint) {
  ConversionResult result = conversionOK;
  UTF32            ch     = *u32CodePoint;

  if(JK_EXPECT_F(ch >= UNI_SUR_HIGH_START) && (JK_EXPECT_T(ch <= UNI_SUR_LOW_END)))                                                        { result = sourceIllegal; ch = UNI_REPLACEMENT_CHAR; goto finished; }
  if(JK_EXPECT_F(ch >= 0xFDD0U) && (JK_EXPECT_F(ch <= 0xFDEFU) || JK_EXPECT_F((ch & 0xFFFEU) == 0xFFFEU)) && JK_EXPECT_T(ch <= 0x10FFFFU)) { result = sourceIllegal; ch = UNI_REPLACEMENT_CHAR; goto finished; }
  if(JK_EXPECT_F(ch == 0U))                                                                                                                { result = sourceIllegal; ch = UNI_REPLACEMENT_CHAR; goto finished; }

 finished:
  *u32CodePoint = ch;
  return(result);
}


static int isLegalUTF8(const UTF8 *source, size_t length) {
  const UTF8 *srcptr = source + length;
  UTF8 a;

  switch(length) {
    default: return(0); // Everything else falls through when "true"...
    case 4: if(JK_EXPECT_F(((a = (*--srcptr)) < 0x80) || (a > 0xBF))) { return(0); }
    case 3: if(JK_EXPECT_F(((a = (*--srcptr)) < 0x80) || (a > 0xBF))) { return(0); }
    case 2: if(JK_EXPECT_F( (a = (*--srcptr)) > 0xBF               )) { return(0); }
      
      switch(*source) { // no fall-through in this inner switch
        case 0xE0: if(JK_EXPECT_F(a < 0xA0)) { return(0); } break;
        case 0xED: if(JK_EXPECT_F(a > 0x9F)) { return(0); } break;
        case 0xF0: if(JK_EXPECT_F(a < 0x90)) { return(0); } break;
        case 0xF4: if(JK_EXPECT_F(a > 0x8F)) { return(0); } break;
        default:   if(JK_EXPECT_F(a < 0x80)) { return(0); }
      }
      
    case 1: if(JK_EXPECT_F((JK_EXPECT_T(*source < 0xC2)) && JK_EXPECT_F(*source >= 0x80))) { return(0); }
  }

  if(JK_EXPECT_F(*source > 0xF4)) { return(0); }

  return(1);
}

static ConversionResult ConvertSingleCodePointInUTF8(const UTF8 *sourceStart, const UTF8 *sourceEnd, UTF8 const **nextUTF8, UTF32 *convertedUTF32) {
  ConversionResult result = conversionOK;
  const UTF8 *source = sourceStart;
  UTF32 ch = 0UL;

#if !defined(JK_FAST_TRAILING_BYTES)
  unsigned short extraBytesToRead = trailingBytesForUTF8[*source];
#else
  unsigned short extraBytesToRead = __builtin_clz(((*source)^0xff) << 25);
#endif

  if(JK_EXPECT_F((source + extraBytesToRead + 1) > sourceEnd) || JK_EXPECT_F(!isLegalUTF8(source, extraBytesToRead + 1))) {
    source++;
    while((source < sourceEnd) && (((*source) & 0xc0) == 0x80) && ((source - sourceStart) < (extraBytesToRead + 1))) { source++; } 
    NSCParameterAssert(source <= sourceEnd);
    result = ((source < sourceEnd) && (((*source) & 0xc0) != 0x80)) ? sourceIllegal : ((sourceStart + extraBytesToRead + 1) > sourceEnd) ? sourceExhausted : sourceIllegal;
    ch = UNI_REPLACEMENT_CHAR;
    goto finished;
  }

  switch(extraBytesToRead) { // The cases all fall through.
    case 5: ch += *source++; ch <<= 6;
    case 4: ch += *source++; ch <<= 6;
    case 3: ch += *source++; ch <<= 6;
    case 2: ch += *source++; ch <<= 6;
    case 1: ch += *source++; ch <<= 6;
    case 0: ch += *source++;
  }
  ch -= offsetsFromUTF8[extraBytesToRead];

  result = isValidCodePoint(&ch);
  
 finished:
  *nextUTF8       = source;
  *convertedUTF32 = ch;
  
  return(result);
}


static ConversionResult ConvertUTF32toUTF8 (UTF32 u32CodePoint, UTF8 **targetStart, UTF8 *targetEnd) {
  const UTF32       byteMask     = 0xBF, byteMark = 0x80;
  ConversionResult  result       = conversionOK;
  UTF8             *target       = *targetStart;
  UTF32             ch           = u32CodePoint;
  unsigned short    bytesToWrite = 0;

  result = isValidCodePoint(&ch);

  // Figure out how many bytes the result will require. Turn any illegally large UTF32 things (> Plane 17) into replacement chars.
       if(ch < (UTF32)0x80)          { bytesToWrite = 1; }
  else if(ch < (UTF32)0x800)         { bytesToWrite = 2; }
  else if(ch < (UTF32)0x10000)       { bytesToWrite = 3; }
  else if(ch <= UNI_MAX_LEGAL_UTF32) { bytesToWrite = 4; }
  else {                               bytesToWrite = 3; ch = UNI_REPLACEMENT_CHAR; result = sourceIllegal; }
        
  target += bytesToWrite;
  if (target > targetEnd) { target -= bytesToWrite; result = targetExhausted; goto finished; }

  switch (bytesToWrite) { // note: everything falls through.
    case 4: *--target = (UTF8)((ch | byteMark) & byteMask); ch >>= 6;
    case 3: *--target = (UTF8)((ch | byteMark) & byteMask); ch >>= 6;
    case 2: *--target = (UTF8)((ch | byteMark) & byteMask); ch >>= 6;
    case 1: *--target = (UTF8) (ch | firstByteMark[bytesToWrite]);
  }

  target += bytesToWrite;

 finished:
  *targetStart = target;
  return(result);
}

JK_STATIC_INLINE int jk_string_add_unicodeCodePoint(JKParseState *parseState, uint32_t unicodeCodePoint, size_t *tokenBufferIdx, JKHash *stringHash) {
  UTF8             *u8s = &parseState->token.tokenBuffer.bytes.ptr[*tokenBufferIdx];
  ConversionResult  result;

  if((result = ConvertUTF32toUTF8(unicodeCodePoint, &u8s, (parseState->token.tokenBuffer.bytes.ptr + parseState->token.tokenBuffer.bytes.length))) != conversionOK) { if(result == targetExhausted) { return(1); } }
  size_t utf8len = u8s - &parseState->token.tokenBuffer.bytes.ptr[*tokenBufferIdx], nextIdx = (*tokenBufferIdx) + utf8len;
  
  while(*tokenBufferIdx < nextIdx) { *stringHash = calculateHash(*stringHash, parseState->token.tokenBuffer.bytes.ptr[(*tokenBufferIdx)++]); }

  return(0);
}


static int jk_parse_string(JKParseState *parseState) {
  NSCParameterAssert((parseState != NULL) && (JK_AT_STRING_PTR(parseState) <= JK_END_STRING_PTR(parseState)));
  const unsigned char *stringStart       = JK_AT_STRING_PTR(parseState) + 1;
  const unsigned char *endOfBuffer       = JK_END_STRING_PTR(parseState);
  const unsigned char *atStringCharacter = stringStart;
  unsigned char       *tokenBuffer       = parseState->token.tokenBuffer.bytes.ptr;
  size_t               tokenStartIndex   = parseState->atIndex;
  size_t               tokenBufferIdx    = 0UL;

  int      onlySimpleString        = 1,  stringState     = JSONStringStateStart;
  uint16_t escapedUnicode1         = 0U, escapedUnicode2 = 0U;
  uint32_t escapedUnicodeCodePoint = 0U;
  JKHash   stringHash              = JK_HASH_INIT;
    
  while(1) {
    unsigned long currentChar;

    if(JK_EXPECT_F(atStringCharacter == endOfBuffer)) { /* XXX Add error message */ stringState = JSONStringStateError; goto finishedParsing; }
    
    if(JK_EXPECT_F((currentChar = *atStringCharacter++) >= 0x80UL)) {
      const unsigned char *nextValidCharacter = NULL;
      UTF32                u32ch              = 0U;
      ConversionResult     result;

      if(JK_EXPECT_F((result = ConvertSingleCodePointInUTF8(atStringCharacter - 1, endOfBuffer, (UTF8 const **)&nextValidCharacter, &u32ch)) != conversionOK)) { goto switchToSlowPath; }
      stringHash = calculateHash(stringHash, currentChar);
      while(atStringCharacter < nextValidCharacter) { stringHash = calculateHash(stringHash, *atStringCharacter++); }
      continue;
    } else {
      if(JK_EXPECT_F(currentChar == (unsigned long)'"')) { stringState = JSONStringStateFinished; goto finishedParsing; }

      if(JK_EXPECT_F(currentChar == (unsigned long)'\\')) {
      switchToSlowPath:
        onlySimpleString = 0;
        stringState      = JSONStringStateParsing;
        tokenBufferIdx   = (atStringCharacter - stringStart) - 1L;
        if(JK_EXPECT_F((tokenBufferIdx + 16UL) > parseState->token.tokenBuffer.bytes.length)) { if((tokenBuffer = jk_managedBuffer_resize(&parseState->token.tokenBuffer, tokenBufferIdx + 1024UL)) == NULL) { jk_error(parseState, @"Internal error: Unable to resize temporary buffer. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); stringState = JSONStringStateError; goto finishedParsing; } }
        memcpy(tokenBuffer, stringStart, tokenBufferIdx);
        goto slowMatch;
      }

      if(JK_EXPECT_F(currentChar < 0x20UL)) { jk_error(parseState, @"Invalid character < 0x20 found in string: 0x%2.2x.", currentChar); stringState = JSONStringStateError; goto finishedParsing; }

      stringHash = calculateHash(stringHash, currentChar);
    }
  }

 slowMatch:

  for(atStringCharacter = (stringStart + ((atStringCharacter - stringStart) - 1L)); (atStringCharacter < endOfBuffer) && (tokenBufferIdx < parseState->token.tokenBuffer.bytes.length); atStringCharacter++) {
    if((tokenBufferIdx + 16UL) > parseState->token.tokenBuffer.bytes.length) { if((tokenBuffer = jk_managedBuffer_resize(&parseState->token.tokenBuffer, tokenBufferIdx + 1024UL)) == NULL) { jk_error(parseState, @"Internal error: Unable to resize temporary buffer. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); stringState = JSONStringStateError; goto finishedParsing; } }

    NSCParameterAssert(tokenBufferIdx < parseState->token.tokenBuffer.bytes.length);

    unsigned long currentChar = (*atStringCharacter), escapedChar;

    if(JK_EXPECT_T(stringState == JSONStringStateParsing)) {
      if(JK_EXPECT_T(currentChar >= 0x20UL)) {
        if(JK_EXPECT_T(currentChar < (unsigned long)0x80)) { // Not a UTF8 sequence
          if(JK_EXPECT_F(currentChar == (unsigned long)'\\')) { stringState = JSONStringStateEscape; continue; }
          if(JK_EXPECT_F(currentChar == (unsigned long)'"'))  { stringState = JSONStringStateFinished; atStringCharacter++; goto finishedParsing; }
          stringHash = calculateHash(stringHash, currentChar);
          tokenBuffer[tokenBufferIdx++] = currentChar;
          continue;
        } else { // UTF8 sequence
          const unsigned char *nextValidCharacter = NULL;
          UTF32                u32ch              = 0U;
          ConversionResult     result;
          
          if(JK_EXPECT_F((result = ConvertSingleCodePointInUTF8(atStringCharacter, endOfBuffer, (UTF8 const **)&nextValidCharacter, &u32ch)) != conversionOK)) {
            if((result == sourceIllegal) && ((parseState->parseOptionFlags & JKParseOptionLooseUnicode) == 0)) { jk_error(parseState, @"Illegal UTF8 sequence found in \"\" string.");              stringState = JSONStringStateError; goto finishedParsing; }
            if(result == sourceExhausted)                                                                      { jk_error(parseState, @"End of buffer reached while parsing UTF8 in \"\" string."); stringState = JSONStringStateError; goto finishedParsing; }
            if(jk_string_add_unicodeCodePoint(parseState, u32ch, &tokenBufferIdx, &stringHash))                { jk_error(parseState, @"Internal error: Unable to add UTF8 sequence to internal string buffer. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); stringState = JSONStringStateError; goto finishedParsing; }
            atStringCharacter = nextValidCharacter - 1;
            continue;
          } else {
            while(atStringCharacter < nextValidCharacter) { tokenBuffer[tokenBufferIdx++] = *atStringCharacter; stringHash = calculateHash(stringHash, *atStringCharacter++); }
            atStringCharacter--;
            continue;
          }
        }
      } else { // currentChar < 0x20
        jk_error(parseState, @"Invalid character < 0x20 found in string: 0x%2.2x.", currentChar); stringState = JSONStringStateError; goto finishedParsing;
      }

    } else { // stringState != JSONStringStateParsing
      int isSurrogate = 1;

      switch(stringState) {
        case JSONStringStateEscape:
          switch(currentChar) {
            case 'u': escapedUnicode1 = 0U; escapedUnicode2 = 0U; escapedUnicodeCodePoint = 0U; stringState = JSONStringStateEscapedUnicode1; break;

            case 'b':  escapedChar = '\b'; goto parsedEscapedChar;
            case 'f':  escapedChar = '\f'; goto parsedEscapedChar;
            case 'n':  escapedChar = '\n'; goto parsedEscapedChar;
            case 'r':  escapedChar = '\r'; goto parsedEscapedChar;
            case 't':  escapedChar = '\t'; goto parsedEscapedChar;
            case '\\': escapedChar = '\\'; goto parsedEscapedChar;
            case '/':  escapedChar = '/';  goto parsedEscapedChar;
            case '"':  escapedChar = '"';  goto parsedEscapedChar;
              
            parsedEscapedChar:
              stringState = JSONStringStateParsing;
              stringHash  = calculateHash(stringHash, escapedChar);
              tokenBuffer[tokenBufferIdx++] = escapedChar;
              break;
              
            default: jk_error(parseState, @"Invalid escape sequence found in \"\" string."); stringState = JSONStringStateError; goto finishedParsing; break;
          }
          break;

        case JSONStringStateEscapedUnicode1:
        case JSONStringStateEscapedUnicode2:
        case JSONStringStateEscapedUnicode3:
        case JSONStringStateEscapedUnicode4:           isSurrogate = 0;
        case JSONStringStateEscapedUnicodeSurrogate1:
        case JSONStringStateEscapedUnicodeSurrogate2:
        case JSONStringStateEscapedUnicodeSurrogate3:
        case JSONStringStateEscapedUnicodeSurrogate4:
          {
            uint16_t hexValue = 0U;

            switch(currentChar) {
              case '0' ... '9': hexValue =  currentChar - '0';        goto parsedHex;
              case 'a' ... 'f': hexValue = (currentChar - 'a') + 10U; goto parsedHex;
              case 'A' ... 'F': hexValue = (currentChar - 'A') + 10U; goto parsedHex;
                
              parsedHex:
              if(!isSurrogate) { escapedUnicode1 = (escapedUnicode1 << 4) | hexValue; } else { escapedUnicode2 = (escapedUnicode2 << 4) | hexValue; }
                
              if(stringState == JSONStringStateEscapedUnicode4) {
                if(((escapedUnicode1 >= 0xD800U) && (escapedUnicode1 < 0xE000U))) {
                  if((escapedUnicode1 >= 0xD800U) && (escapedUnicode1 < 0xDC00U)) { stringState = JSONStringStateEscapedNeedEscapeForSurrogate; }
                  else if((escapedUnicode1 >= 0xDC00U) && (escapedUnicode1 < 0xE000U)) { 
                    if((parseState->parseOptionFlags & JKParseOptionLooseUnicode)) { escapedUnicodeCodePoint = UNI_REPLACEMENT_CHAR; }
                    else { jk_error(parseState, @"Illegal \\u Unicode escape sequence."); stringState = JSONStringStateError; goto finishedParsing; }
                  }
                }
                else { escapedUnicodeCodePoint = escapedUnicode1; }
              }

              if(stringState == JSONStringStateEscapedUnicodeSurrogate4) {
                if((escapedUnicode2 < 0xdc00) || (escapedUnicode2 > 0xdfff)) {
                  if((parseState->parseOptionFlags & JKParseOptionLooseUnicode)) { escapedUnicodeCodePoint = UNI_REPLACEMENT_CHAR; }
                  else { jk_error(parseState, @"Illegal \\u Unicode escape sequence."); stringState = JSONStringStateError; goto finishedParsing; }
                }
                else { escapedUnicodeCodePoint = ((escapedUnicode1 - 0xd800) * 0x400) + (escapedUnicode2 - 0xdc00) + 0x10000; }
              }
                
              if((stringState == JSONStringStateEscapedUnicode4) || (stringState == JSONStringStateEscapedUnicodeSurrogate4)) { 
                if((isValidCodePoint(&escapedUnicodeCodePoint) == sourceIllegal) && ((parseState->parseOptionFlags & JKParseOptionLooseUnicode) == 0)) { jk_error(parseState, @"Illegal \\u Unicode escape sequence."); stringState = JSONStringStateError; goto finishedParsing; }
                stringState = JSONStringStateParsing;
                if(jk_string_add_unicodeCodePoint(parseState, escapedUnicodeCodePoint, &tokenBufferIdx, &stringHash)) { jk_error(parseState, @"Internal error: Unable to add UTF8 sequence to internal string buffer. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); stringState = JSONStringStateError; goto finishedParsing; }
              }
              else if((stringState >= JSONStringStateEscapedUnicode1) && (stringState <= JSONStringStateEscapedUnicodeSurrogate4)) { stringState++; }
              break;

              default: jk_error(parseState, @"Unexpected character found in \\u Unicode escape sequence.  Found '%c', expected [0-9a-fA-F].", currentChar); stringState = JSONStringStateError; goto finishedParsing; break;
            }
          }
          break;

        case JSONStringStateEscapedNeedEscapeForSurrogate:
          if((currentChar == '\\')) { stringState = JSONStringStateEscapedNeedEscapedUForSurrogate; }
          else { 
            if((parseState->parseOptionFlags & JKParseOptionLooseUnicode) == 0) { jk_error(parseState, @"Required a second \\u Unicode escape sequence following a surrogate \\u Unicode escape sequence."); stringState = JSONStringStateError; goto finishedParsing; }
            else { stringState = JSONStringStateParsing; atStringCharacter--;    if(jk_string_add_unicodeCodePoint(parseState, UNI_REPLACEMENT_CHAR, &tokenBufferIdx, &stringHash)) { jk_error(parseState, @"Internal error: Unable to add UTF8 sequence to internal string buffer. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); stringState = JSONStringStateError; goto finishedParsing; } }
          }
          break;

        case JSONStringStateEscapedNeedEscapedUForSurrogate:
          if(currentChar == 'u') { stringState = JSONStringStateEscapedUnicodeSurrogate1; }
          else { 
            if((parseState->parseOptionFlags & JKParseOptionLooseUnicode) == 0) { jk_error(parseState, @"Required a second \\u Unicode escape sequence following a surrogate \\u Unicode escape sequence."); stringState = JSONStringStateError; goto finishedParsing; }
            else { stringState = JSONStringStateParsing; atStringCharacter -= 2; if(jk_string_add_unicodeCodePoint(parseState, UNI_REPLACEMENT_CHAR, &tokenBufferIdx, &stringHash)) { jk_error(parseState, @"Internal error: Unable to add UTF8 sequence to internal string buffer. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); stringState = JSONStringStateError; goto finishedParsing; } }
          }
          break;

        default: jk_error(parseState, @"Internal error: Unknown stringState. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); stringState = JSONStringStateError; goto finishedParsing; break;
      }
    }
  }

finishedParsing:

  if(JK_EXPECT_T(stringState == JSONStringStateFinished)) {
    NSCParameterAssert((parseState->stringBuffer.bytes.ptr + tokenStartIndex) < atStringCharacter);

    parseState->token.tokenPtrRange.ptr    = parseState->stringBuffer.bytes.ptr + tokenStartIndex;
    parseState->token.tokenPtrRange.length = (atStringCharacter - parseState->token.tokenPtrRange.ptr);

    if(JK_EXPECT_T(onlySimpleString)) {
      NSCParameterAssert(((parseState->token.tokenPtrRange.ptr + 1) < endOfBuffer) && (parseState->token.tokenPtrRange.length >= 2UL) && (((parseState->token.tokenPtrRange.ptr + 1) + (parseState->token.tokenPtrRange.length - 2)) < endOfBuffer));
      parseState->token.value.ptrRange.ptr    = parseState->token.tokenPtrRange.ptr    + 1;
      parseState->token.value.ptrRange.length = parseState->token.tokenPtrRange.length - 2UL;
    } else {
      parseState->token.value.ptrRange.ptr    = parseState->token.tokenBuffer.bytes.ptr;
      parseState->token.value.ptrRange.length = tokenBufferIdx;
    }
    
    parseState->token.value.hash = stringHash;
    parseState->token.value.type = JKValueTypeString;
    parseState->atIndex          = (atStringCharacter - parseState->stringBuffer.bytes.ptr);
  }

  if(JK_EXPECT_F(stringState != JSONStringStateFinished)) { jk_error(parseState, @"Invalid string."); }
  return(JK_EXPECT_T(stringState == JSONStringStateFinished) ? 0 : 1);
}

static int jk_parse_number(JKParseState *parseState) {
  NSCParameterAssert((parseState != NULL) && (JK_AT_STRING_PTR(parseState) <= JK_END_STRING_PTR(parseState)));
  const unsigned char *numberStart       = JK_AT_STRING_PTR(parseState);
  const unsigned char *endOfBuffer       = JK_END_STRING_PTR(parseState);
  const unsigned char *atNumberCharacter = NULL;
  int                  numberState       = JSONNumberStateWholeNumberStart, isFloatingPoint = 0, isNegative = 0, backup = 0;
  size_t               startingIndex     = parseState->atIndex;
  
  for(atNumberCharacter = numberStart; (JK_EXPECT_T(atNumberCharacter < endOfBuffer)) && (JK_EXPECT_T(!(JK_EXPECT_F(numberState == JSONNumberStateFinished) || JK_EXPECT_F(numberState == JSONNumberStateError)))); atNumberCharacter++) {
    unsigned long currentChar = (unsigned long)(*atNumberCharacter), lowerCaseCC = currentChar | 0x20UL;
    
    switch(numberState) {
      case JSONNumberStateWholeNumberStart: if   (currentChar == '-')                                                                              { numberState = JSONNumberStateWholeNumberMinus;      isNegative      = 1; break; }
      case JSONNumberStateWholeNumberMinus: if   (currentChar == '0')                                                                              { numberState = JSONNumberStateWholeNumberZero;                            break; }
                                       else if(  (currentChar >= '1') && (currentChar <= '9'))                                                     { numberState = JSONNumberStateWholeNumber;                                break; }
                                       else                                                     { /* XXX Add error message */                        numberState = JSONNumberStateError;                                      break; }
      case JSONNumberStateExponentStart:    if(  (currentChar == '+') || (currentChar == '-'))                                                     { numberState = JSONNumberStateExponentPlusMinus;                          break; }
      case JSONNumberStateFractionalNumberStart:
      case JSONNumberStateExponentPlusMinus:if(!((currentChar >= '0') && (currentChar <= '9'))) { /* XXX Add error message */                        numberState = JSONNumberStateError;                                      break; }
                                       else {                                              if(numberState == JSONNumberStateFractionalNumberStart) { numberState = JSONNumberStateFractionalNumber; }
                                                                                           else                                                    { numberState = JSONNumberStateExponent;         }                         break; }
      case JSONNumberStateWholeNumberZero:
      case JSONNumberStateWholeNumber:      if   (currentChar == '.')                                                                              { numberState = JSONNumberStateFractionalNumberStart; isFloatingPoint = 1; break; }
      case JSONNumberStateFractionalNumber: if   (lowerCaseCC == 'e')                                                                              { numberState = JSONNumberStateExponentStart;         isFloatingPoint = 1; break; }
      case JSONNumberStateExponent:         if(!((currentChar >= '0') && (currentChar <= '9')) || (numberState == JSONNumberStateWholeNumberZero)) { numberState = JSONNumberStateFinished;              backup          = 1; break; }
        break;
      default:                                                                                    /* XXX Add error message */                        numberState = JSONNumberStateError;                                      break;
    }
  }
  
  parseState->token.tokenPtrRange.ptr    = parseState->stringBuffer.bytes.ptr + startingIndex;
  parseState->token.tokenPtrRange.length = (atNumberCharacter - parseState->token.tokenPtrRange.ptr) - backup;
  parseState->atIndex                    = (parseState->token.tokenPtrRange.ptr + parseState->token.tokenPtrRange.length) - parseState->stringBuffer.bytes.ptr;

  if(JK_EXPECT_T(numberState == JSONNumberStateFinished)) {
    unsigned char  numberTempBuf[parseState->token.tokenPtrRange.length + 4UL];
    unsigned char *endOfNumber = NULL;

    memcpy(numberTempBuf, parseState->token.tokenPtrRange.ptr, parseState->token.tokenPtrRange.length);
    numberTempBuf[parseState->token.tokenPtrRange.length] = 0;

    errno = 0;
    
    // Treat "-0" as a floating point number, which is capable of representing negative zeros.
    if(JK_EXPECT_F(parseState->token.tokenPtrRange.length == 2UL) && JK_EXPECT_F(numberTempBuf[1] == '0') && JK_EXPECT_F(isNegative)) { isFloatingPoint = 1; }

    if(isFloatingPoint) {
      parseState->token.value.number.doubleValue = strtod((const char *)numberTempBuf, (char **)&endOfNumber);
      parseState->token.value.type               = JKValueTypeDouble;
      parseState->token.value.ptrRange.ptr       = (const unsigned char *)&parseState->token.value.number.doubleValue;
      parseState->token.value.ptrRange.length    = sizeof(double);
      parseState->token.value.hash               = (JK_HASH_INIT + parseState->token.value.type);
    } else {
      if(isNegative) {
        parseState->token.value.number.longLongValue = strtoll((const char *)numberTempBuf, (char **)&endOfNumber, 10);
        parseState->token.value.type                 = JKValueTypeLongLong;
        parseState->token.value.ptrRange.ptr         = (const unsigned char *)&parseState->token.value.number.longLongValue;
        parseState->token.value.ptrRange.length      = sizeof(long long);
        parseState->token.value.hash                 = (JK_HASH_INIT + parseState->token.value.type) + (JKHash)parseState->token.value.number.longLongValue;
      } else {
        parseState->token.value.number.unsignedLongLongValue = strtoull((const char *)numberTempBuf, (char **)&endOfNumber, 10);
        parseState->token.value.type                         = JKValueTypeUnsignedLongLong;
        parseState->token.value.ptrRange.ptr                 = (const unsigned char *)&parseState->token.value.number.unsignedLongLongValue;
        parseState->token.value.ptrRange.length              = sizeof(unsigned long long);
        parseState->token.value.hash                         = (JK_HASH_INIT + parseState->token.value.type) + (JKHash)parseState->token.value.number.unsignedLongLongValue;
      }
    }

    if(JK_EXPECT_F(errno != 0)) {
      numberState = JSONNumberStateError;
      if(errno == ERANGE) {
        switch(parseState->token.value.type) {
          case JKValueTypeDouble:           jk_error(parseState, @"The value '%s' could not be represented as a 'double' due to %s.",           numberTempBuf, (parseState->token.value.number.doubleValue == 0.0) ? "underflow" : "overflow"); break;
          case JKValueTypeLongLong:         jk_error(parseState, @"The value '%s' exceeded the minimum value that could be represented: %lld.", numberTempBuf, parseState->token.value.number.longLongValue); break;
          case JKValueTypeUnsignedLongLong: jk_error(parseState, @"The value '%s' exceeded the maximum value that could be represented: %llu.", numberTempBuf, parseState->token.value.number.unsignedLongLongValue); break;
          default:                          jk_error(parseState, @"Internal error: Unknown token value type. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); break;
        }
      }
    }
    if(JK_EXPECT_F(endOfNumber != &numberTempBuf[parseState->token.tokenPtrRange.length]) && JK_EXPECT_F(numberState != JSONNumberStateError)) { numberState = JSONNumberStateError; jk_error(parseState, @"The conversion function did not consume all of the number tokens characters."); }

    size_t hashIndex = 0UL;
    for(hashIndex = 0UL; hashIndex < parseState->token.value.ptrRange.length; hashIndex++) { parseState->token.value.hash = calculateHash(parseState->token.value.hash, parseState->token.value.ptrRange.ptr[hashIndex]); }
  }

  if(JK_EXPECT_F(numberState != JSONNumberStateFinished)) { jk_error(parseState, @"Invalid number."); }
  return(JK_EXPECT_T((numberState == JSONNumberStateFinished)) ? 0 : 1);
}

JK_STATIC_INLINE void jk_set_parsed_token(JKParseState *parseState, const unsigned char *ptr, size_t length, JKTokenType type, size_t advanceBy) {
  parseState->token.tokenPtrRange.ptr     = ptr;
  parseState->token.tokenPtrRange.length  = length;
  parseState->token.type                  = type;
  parseState->atIndex                    += advanceBy;
}

static size_t jk_parse_is_newline(JKParseState *parseState, const unsigned char *atCharacterPtr) {
  NSCParameterAssert((parseState != NULL) && (atCharacterPtr != NULL) && (atCharacterPtr >= parseState->stringBuffer.bytes.ptr) && (atCharacterPtr < JK_END_STRING_PTR(parseState)));
  const unsigned char *endOfStringPtr = JK_END_STRING_PTR(parseState);

  if(JK_EXPECT_F(atCharacterPtr >= endOfStringPtr)) { return(0UL); }

  if(JK_EXPECT_F((*(atCharacterPtr + 0)) == '\n')) { return(1UL); }
  if(JK_EXPECT_F((*(atCharacterPtr + 0)) == '\r')) { if((JK_EXPECT_T((atCharacterPtr + 1) < endOfStringPtr)) && ((*(atCharacterPtr + 1)) == '\n')) { return(2UL); } return(1UL); }
  if(parseState->parseOptionFlags & JKParseOptionUnicodeNewlines) {
    if((JK_EXPECT_F((*(atCharacterPtr + 0)) == 0xc2)) && (((atCharacterPtr + 1) < endOfStringPtr) && ((*(atCharacterPtr + 1)) == 0x85))) { return(2UL); }
    if((JK_EXPECT_F((*(atCharacterPtr + 0)) == 0xe2)) && (((atCharacterPtr + 2) < endOfStringPtr) && ((*(atCharacterPtr + 1)) == 0x80) && (((*(atCharacterPtr + 2)) == 0xa8) || ((*(atCharacterPtr + 2)) == 0xa9)))) { return(3UL); }
  }

  return(0UL);
}

JK_STATIC_INLINE int jk_parse_skip_newline(JKParseState *parseState) {
  size_t newlineAdvanceAtIndex = 0UL;
  if(JK_EXPECT_F((newlineAdvanceAtIndex = jk_parse_is_newline(parseState, JK_AT_STRING_PTR(parseState))) > 0UL)) { parseState->lineNumber++; parseState->atIndex += (newlineAdvanceAtIndex - 1UL); parseState->lineStartIndex = parseState->atIndex + 1UL; return(1); }
  return(0);
}

JK_STATIC_INLINE void jk_parse_skip_whitespace(JKParseState *parseState) {
#ifndef __clang_analyzer__
  NSCParameterAssert((parseState != NULL) && (JK_AT_STRING_PTR(parseState) <= JK_END_STRING_PTR(parseState)));
  const unsigned char *atCharacterPtr   = NULL;
  const unsigned char *endOfStringPtr   = JK_END_STRING_PTR(parseState);

  for(atCharacterPtr = JK_AT_STRING_PTR(parseState); (JK_EXPECT_T((atCharacterPtr = JK_AT_STRING_PTR(parseState)) < endOfStringPtr)); parseState->atIndex++) {
    if(((*(atCharacterPtr + 0)) == ' ') || ((*(atCharacterPtr + 0)) == '\t')) { continue; }
    if(jk_parse_skip_newline(parseState)) { continue; }
    if(parseState->parseOptionFlags & JKParseOptionComments) {
      if((JK_EXPECT_F((*(atCharacterPtr + 0)) == '/')) && (JK_EXPECT_T((atCharacterPtr + 1) < endOfStringPtr))) {
        if((*(atCharacterPtr + 1)) == '/') {
          parseState->atIndex++;
          for(atCharacterPtr = JK_AT_STRING_PTR(parseState); (JK_EXPECT_T((atCharacterPtr = JK_AT_STRING_PTR(parseState)) < endOfStringPtr)); parseState->atIndex++) { if(jk_parse_skip_newline(parseState)) { break; } }
          continue;
        }
        if((*(atCharacterPtr + 1)) == '*') {
          parseState->atIndex++;
          for(atCharacterPtr = JK_AT_STRING_PTR(parseState); (JK_EXPECT_T((atCharacterPtr = JK_AT_STRING_PTR(parseState)) < endOfStringPtr)); parseState->atIndex++) {
            if(jk_parse_skip_newline(parseState)) { continue; }
            if(((*(atCharacterPtr + 0)) == '*') && (((atCharacterPtr + 1) < endOfStringPtr) && ((*(atCharacterPtr + 1)) == '/'))) { parseState->atIndex++; break; }
          }
          continue;
        }
      }
    }
    break;
  }
#endif
}

static int jk_parse_next_token(JKParseState *parseState) {
  NSCParameterAssert((parseState != NULL) && (JK_AT_STRING_PTR(parseState) <= JK_END_STRING_PTR(parseState)));
  const unsigned char *atCharacterPtr   = NULL;
  const unsigned char *endOfStringPtr   = JK_END_STRING_PTR(parseState);
  unsigned char        currentCharacter = 0U;
  int                  stopParsing      = 0;

  parseState->prev_atIndex        = parseState->atIndex;
  parseState->prev_lineNumber     = parseState->lineNumber;
  parseState->prev_lineStartIndex = parseState->lineStartIndex;

  jk_parse_skip_whitespace(parseState);

  if((JK_AT_STRING_PTR(parseState) == endOfStringPtr)) { stopParsing = 1; }

  if((JK_EXPECT_T(stopParsing == 0)) && (JK_EXPECT_T((atCharacterPtr = JK_AT_STRING_PTR(parseState)) < endOfStringPtr))) {
    currentCharacter = *atCharacterPtr;

    switch(currentCharacter) {
      case '{': jk_set_parsed_token(parseState, atCharacterPtr, 1UL, JKTokenTypeObjectBegin, 1UL); break;
      case '}': jk_set_parsed_token(parseState, atCharacterPtr, 1UL, JKTokenTypeObjectEnd,   1UL); break;
      case '[': jk_set_parsed_token(parseState, atCharacterPtr, 1UL, JKTokenTypeArrayBegin,  1UL); break;
      case ']': jk_set_parsed_token(parseState, atCharacterPtr, 1UL, JKTokenTypeArrayEnd,    1UL); break;
      case ',': jk_set_parsed_token(parseState, atCharacterPtr, 1UL, JKTokenTypeComma,       1UL); break;
      case ':': jk_set_parsed_token(parseState, atCharacterPtr, 1UL, JKTokenTypeSeparator,   1UL); break;

      case 't': if(!((JK_EXPECT_T((atCharacterPtr + 4UL) < endOfStringPtr)) && (JK_EXPECT_T(atCharacterPtr[1] == 'r')) && (JK_EXPECT_T(atCharacterPtr[2] == 'u')) && (JK_EXPECT_T(atCharacterPtr[3] == 'e'))))                                            { stopParsing = 1; /* XXX Add error message */ } else { jk_set_parsed_token(parseState, atCharacterPtr, 4UL, JKTokenTypeTrue,  4UL); } break;
      case 'f': if(!((JK_EXPECT_T((atCharacterPtr + 5UL) < endOfStringPtr)) && (JK_EXPECT_T(atCharacterPtr[1] == 'a')) && (JK_EXPECT_T(atCharacterPtr[2] == 'l')) && (JK_EXPECT_T(atCharacterPtr[3] == 's')) && (JK_EXPECT_T(atCharacterPtr[4] == 'e')))) { stopParsing = 1; /* XXX Add error message */ } else { jk_set_parsed_token(parseState, atCharacterPtr, 5UL, JKTokenTypeFalse, 5UL); } break;
      case 'n': if(!((JK_EXPECT_T((atCharacterPtr + 4UL) < endOfStringPtr)) && (JK_EXPECT_T(atCharacterPtr[1] == 'u')) && (JK_EXPECT_T(atCharacterPtr[2] == 'l')) && (JK_EXPECT_T(atCharacterPtr[3] == 'l'))))                                            { stopParsing = 1; /* XXX Add error message */ } else { jk_set_parsed_token(parseState, atCharacterPtr, 4UL, JKTokenTypeNull,  4UL); } break;

      case '"': if(JK_EXPECT_T((stopParsing = jk_parse_string(parseState)) == 0)) { jk_set_parsed_token(parseState, parseState->token.tokenPtrRange.ptr, parseState->token.tokenPtrRange.length, JKTokenTypeString, 0UL); } break;

      case '-': // fall-thru
      case '0' ... '9': if(JK_EXPECT_T((stopParsing = jk_parse_number(parseState)) == 0)) { jk_set_parsed_token(parseState, parseState->token.tokenPtrRange.ptr, parseState->token.tokenPtrRange.length, JKTokenTypeNumber, 0UL); } break;

      default: stopParsing = 1; /* XXX Add error message */ break;
    }
  }

  if(JK_EXPECT_F(stopParsing)) { jk_error(parseState, @"Unexpected token, wanted '{', '}', '[', ']', ',', ':', 'true', 'false', 'null', '\"STRING\"', 'NUMBER'."); }
  return(stopParsing);
}

JK_STATIC_INLINE void jk_cache_age(JKParseState *parseState) {
  parseState->cache.prng_lcg = (parseState->cache.prng_lcg * 0x41c64e6dU) + 0x3039U;
  parseState->cache.items[parseState->cache.prng_lcg & (parseState->cache.count - 1UL)].age >>= 1;
}

static void *jk_cachedObjects(JKParseState *parseState) {
  unsigned long  bucket     = parseState->token.value.hash & (parseState->cache.count - 1UL), setBucket = 0UL, useableBucket = 0UL, x = 0UL;
  void          *parsedAtom = NULL;

  jk_cache_age(parseState);

  if(JK_EXPECT_F(parseState->token.value.ptrRange.length == 0UL) && JK_EXPECT_T(parseState->token.value.type == JKValueTypeString)) { return(@""); }

  for(x = 0UL; x < JK_CACHE_PROBES; x++) {
    if(JK_EXPECT_F(parseState->cache.items[bucket].object == NULL)) { setBucket = 1UL; useableBucket = bucket; break; }

    if((JK_EXPECT_T(parseState->cache.items[bucket].hash == parseState->token.value.hash)) && (JK_EXPECT_T(parseState->cache.items[bucket].size == parseState->token.value.ptrRange.length)) && (JK_EXPECT_T(parseState->cache.items[bucket].type == parseState->token.value.type)) && (JK_EXPECT_T(parseState->cache.items[bucket].bytes != NULL)) && (JK_EXPECT_T(strncmp((const char *)parseState->cache.items[bucket].bytes, (const char *)parseState->token.value.ptrRange.ptr, parseState->token.value.ptrRange.length) == 0U))) {
      parseState->cache.items[bucket].age = (parseState->cache.items[bucket].age << 1) | 1U;
      parseState->token.value.cacheItem   = &parseState->cache.items[bucket];
      NSCParameterAssert(parseState->cache.items[bucket].object != NULL);
      return((void *)CFRetain(parseState->cache.items[bucket].object));
    } else {
      if(JK_EXPECT_F(setBucket == 0UL) && JK_EXPECT_F(parseState->cache.items[bucket].age == 0U)) { setBucket = 1UL; useableBucket = bucket; }
      if(JK_EXPECT_F(setBucket == 0UL))                                                           { parseState->cache.items[bucket].age >>= 1; jk_cache_age(parseState); }
      jk_cache_age(parseState);
      bucket = (parseState->token.value.hash + (parseState->token.value.ptrRange.length * (x + 1UL)) + (parseState->token.value.type * (x + 1UL)) + (3UL * (x + 1UL))) & (parseState->cache.count - 1UL);
    }
  }

  switch(parseState->token.value.type) {
    case JKValueTypeString:           parsedAtom = (void *)CFStringCreateWithBytes(NULL, parseState->token.value.ptrRange.ptr, parseState->token.value.ptrRange.length, kCFStringEncodingUTF8, 0); break;
    case JKValueTypeLongLong:         parsedAtom = (void *)CFNumberCreate(NULL, kCFNumberLongLongType, &parseState->token.value.number.longLongValue);                                             break;
    case JKValueTypeUnsignedLongLong:
      if(parseState->token.value.number.unsignedLongLongValue <= LLONG_MAX) { parsedAtom = (void *)CFNumberCreate(NULL, kCFNumberLongLongType, &parseState->token.value.number.unsignedLongLongValue); }
      else { parsedAtom = (void *)parseState->objCImpCache.NSNumberInitWithUnsignedLongLong(parseState->objCImpCache.NSNumberAlloc(parseState->objCImpCache.NSNumberClass, @selector(alloc)), @selector(initWithUnsignedLongLong:), parseState->token.value.number.unsignedLongLongValue); }
      break;
    case JKValueTypeDouble:           parsedAtom = (void *)CFNumberCreate(NULL, kCFNumberDoubleType,   &parseState->token.value.number.doubleValue);                                               break;
    default: jk_error(parseState, @"Internal error: Unknown token value type. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); break;
  }
  
  if(JK_EXPECT_T(setBucket) && (JK_EXPECT_T(parsedAtom != NULL))) {
    bucket = useableBucket;
    if(JK_EXPECT_T((parseState->cache.items[bucket].object != NULL))) { CFRelease(parseState->cache.items[bucket].object); parseState->cache.items[bucket].object = NULL; }

    if(JK_EXPECT_T((parseState->cache.items[bucket].bytes = (unsigned char *)reallocf(parseState->cache.items[bucket].bytes, parseState->token.value.ptrRange.length)) != NULL)) {
      memcpy(parseState->cache.items[bucket].bytes, parseState->token.value.ptrRange.ptr, parseState->token.value.ptrRange.length);
      parseState->cache.items[bucket].object = (void *)CFRetain(parsedAtom);
      parseState->cache.items[bucket].hash   = parseState->token.value.hash;
      parseState->cache.items[bucket].cfHash = 0UL;
      parseState->cache.items[bucket].size   = parseState->token.value.ptrRange.length;
      parseState->cache.items[bucket].age    = JK_INIT_CACHE_AGE;
      parseState->cache.items[bucket].type   = parseState->token.value.type;
      parseState->token.value.cacheItem      = &parseState->cache.items[bucket];
    }
  }

  return(parsedAtom);
}

static void *jk_object_for_token(JKParseState *parseState) {
  void *parsedAtom = NULL;

  parseState->token.value.cacheItem = NULL;
  switch(parseState->token.type) {
    case JKTokenTypeString:      parsedAtom = jk_cachedObjects(parseState);    break;
    case JKTokenTypeNumber:      parsedAtom = jk_cachedObjects(parseState);    break;
    case JKTokenTypeObjectBegin: parsedAtom = jk_parse_dictionary(parseState); break;
    case JKTokenTypeArrayBegin:  parsedAtom = jk_parse_array(parseState);      break;
    case JKTokenTypeTrue:        parsedAtom = (void *)kCFBooleanTrue;          break;
    case JKTokenTypeFalse:       parsedAtom = (void *)kCFBooleanFalse;         break;
    case JKTokenTypeNull:        parsedAtom = (void *)kCFNull;                 break;
    default: jk_error(parseState, @"Internal error: Unknown token type. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); break;
  }

  return(parsedAtom);
}

static void jk_error_parse_accept_or3(JKParseState *parseState, int state, NSString *or1String, NSString *or2String, NSString *or3String) {
  NSString *acceptStrings[16];
  int acceptIdx = 0;
  if(state & JKParseAcceptValue) { acceptStrings[acceptIdx++] = or1String; }
  if(state & JKParseAcceptComma) { acceptStrings[acceptIdx++] = or2String; }
  if(state & JKParseAcceptEnd)   { acceptStrings[acceptIdx++] = or3String; }
       if(acceptIdx == 1) { jk_error(parseState, @"Expected %@, not '%*.*s'",           acceptStrings[0],                                     (int)parseState->token.tokenPtrRange.length, (int)parseState->token.tokenPtrRange.length, parseState->token.tokenPtrRange.ptr); }
  else if(acceptIdx == 2) { jk_error(parseState, @"Expected %@ or %@, not '%*.*s'",     acceptStrings[0], acceptStrings[1],                   (int)parseState->token.tokenPtrRange.length, (int)parseState->token.tokenPtrRange.length, parseState->token.tokenPtrRange.ptr); }
  else if(acceptIdx == 3) { jk_error(parseState, @"Expected %@, %@, or %@, not '%*.*s", acceptStrings[0], acceptStrings[1], acceptStrings[2], (int)parseState->token.tokenPtrRange.length, (int)parseState->token.tokenPtrRange.length, parseState->token.tokenPtrRange.ptr); }
}

static void *jk_parse_array(JKParseState *parseState) {
  size_t  startingObjectIndex = parseState->objectStack.index;
  int     arrayState          = JKParseAcceptValueOrEnd, stopParsing = 0;
  void   *parsedArray         = NULL;

  while(JK_EXPECT_T((JK_EXPECT_T(stopParsing == 0)) && (JK_EXPECT_T(parseState->atIndex < parseState->stringBuffer.bytes.length)))) {
    if(JK_EXPECT_F(parseState->objectStack.index > (parseState->objectStack.count - 4UL))) { if(jk_objectStack_resize(&parseState->objectStack, parseState->objectStack.count + 128UL)) { jk_error(parseState, @"Internal error: [array] objectsIndex > %zu, resize failed? %@ line %#ld", (parseState->objectStack.count - 4UL), [NSString stringWithUTF8String:__FILE__], (long)__LINE__); break; } }

    if(JK_EXPECT_T((stopParsing = jk_parse_next_token(parseState)) == 0)) {
      void *object = NULL;
#ifndef NS_BLOCK_ASSERTIONS
      parseState->objectStack.objects[parseState->objectStack.index] = NULL;
      parseState->objectStack.keys   [parseState->objectStack.index] = NULL;
#endif
      switch(parseState->token.type) {
        case JKTokenTypeNumber:
        case JKTokenTypeString:
        case JKTokenTypeTrue:
        case JKTokenTypeFalse:
        case JKTokenTypeNull:
        case JKTokenTypeArrayBegin:
        case JKTokenTypeObjectBegin:
          if(JK_EXPECT_F((arrayState & JKParseAcceptValue)          == 0))    { parseState->errorIsPrev = 1; jk_error(parseState, @"Unexpected value.");              stopParsing = 1; break; }
          if(JK_EXPECT_F((object = jk_object_for_token(parseState)) == NULL)) {                              jk_error(parseState, @"Internal error: Object == NULL"); stopParsing = 1; break; } else { parseState->objectStack.objects[parseState->objectStack.index++] = object; arrayState = JKParseAcceptCommaOrEnd; }
          break;
        case JKTokenTypeArrayEnd: if(JK_EXPECT_T(arrayState & JKParseAcceptEnd)) { NSCParameterAssert(parseState->objectStack.index >= startingObjectIndex); parsedArray = (void *)_JKArrayCreate((id *)&parseState->objectStack.objects[startingObjectIndex], (parseState->objectStack.index - startingObjectIndex)); } else { parseState->errorIsPrev = 1; jk_error(parseState, @"Unexpected ']'."); } stopParsing = 1; break;
        case JKTokenTypeComma:    if(JK_EXPECT_T(arrayState & JKParseAcceptComma)) { arrayState = JKParseAcceptValue; } else { parseState->errorIsPrev = 1; jk_error(parseState, @"Unexpected ','."); stopParsing = 1; } break;
        default: parseState->errorIsPrev = 1; jk_error_parse_accept_or3(parseState, arrayState, @"a value", @"a comma", @"a ']'"); stopParsing = 1; break;
      }
    }
  }

  if(JK_EXPECT_F(parsedArray == NULL)) { size_t idx = 0UL; for(idx = startingObjectIndex; idx < parseState->objectStack.index; idx++) { if(parseState->objectStack.objects[idx] != NULL) { CFRelease(parseState->objectStack.objects[idx]); parseState->objectStack.objects[idx] = NULL; } } }
#if !defined(NS_BLOCK_ASSERTIONS)
  else { size_t idx = 0UL; for(idx = startingObjectIndex; idx < parseState->objectStack.index; idx++) { parseState->objectStack.objects[idx] = NULL; parseState->objectStack.keys[idx] = NULL; } }
#endif
  
  parseState->objectStack.index = startingObjectIndex;
  return(parsedArray);
}

static void *jk_create_dictionary(JKParseState *parseState, size_t startingObjectIndex) {
  void *parsedDictionary = NULL;

  parseState->objectStack.index--;

  parsedDictionary = _JKDictionaryCreate((id *)&parseState->objectStack.keys[startingObjectIndex], &parseState->objectStack.cfHashes[startingObjectIndex], (id *)&parseState->objectStack.objects[startingObjectIndex], (parseState->objectStack.index - startingObjectIndex));

  return(parsedDictionary);
}

static void *jk_parse_dictionary(JKParseState *parseState) {
  size_t  startingObjectIndex = parseState->objectStack.index;
  int     dictState           = JKParseAcceptValueOrEnd, stopParsing = 0;
  void   *parsedDictionary    = NULL;

  while(JK_EXPECT_T((JK_EXPECT_T(stopParsing == 0)) && (JK_EXPECT_T(parseState->atIndex < parseState->stringBuffer.bytes.length)))) {
    if(JK_EXPECT_F(parseState->objectStack.index > (parseState->objectStack.count - 4UL))) { if(jk_objectStack_resize(&parseState->objectStack, parseState->objectStack.count + 128UL)) { jk_error(parseState, @"Internal error: [dictionary] objectsIndex > %zu, resize failed? %@ line #%ld", (parseState->objectStack.count - 4UL), [NSString stringWithUTF8String:__FILE__], (long)__LINE__); break; } }

    size_t objectStackIndex = parseState->objectStack.index++;
    parseState->objectStack.keys[objectStackIndex]    = NULL;
    parseState->objectStack.objects[objectStackIndex] = NULL;
    void *key = NULL, *object = NULL;

    if(JK_EXPECT_T((JK_EXPECT_T(stopParsing == 0)) && (JK_EXPECT_T((stopParsing = jk_parse_next_token(parseState)) == 0)))) {
      switch(parseState->token.type) {
        case JKTokenTypeString:
          if(JK_EXPECT_F((dictState & JKParseAcceptValue)        == 0))    { parseState->errorIsPrev = 1; jk_error(parseState, @"Unexpected string.");           stopParsing = 1; break; }
          if(JK_EXPECT_F((key = jk_object_for_token(parseState)) == NULL)) {                              jk_error(parseState, @"Internal error: Key == NULL."); stopParsing = 1; break; }
          else {
            parseState->objectStack.keys[objectStackIndex] = key;
            if(JK_EXPECT_T(parseState->token.value.cacheItem != NULL)) {
              if((parseState->token.value.cacheItem->cfHash == 0UL)) { parseState->token.value.cacheItem->cfHash = CFHash(key); }
              parseState->objectStack.cfHashes[objectStackIndex] = parseState->token.value.cacheItem->cfHash;
            } else {
              parseState->objectStack.cfHashes[objectStackIndex] = CFHash(key);
            }
          }
          break;

        case JKTokenTypeObjectEnd: if((JK_EXPECT_T(dictState & JKParseAcceptEnd)))   { NSCParameterAssert(parseState->objectStack.index >= startingObjectIndex); parsedDictionary = jk_create_dictionary(parseState, startingObjectIndex); } else { parseState->errorIsPrev = 1; jk_error(parseState, @"Unexpected '}'."); } stopParsing = 1; break;
        case JKTokenTypeComma:     if((JK_EXPECT_T(dictState & JKParseAcceptComma))) { dictState = JKParseAcceptValue; parseState->objectStack.index--; continue; } else { parseState->errorIsPrev = 1; jk_error(parseState, @"Unexpected ','."); stopParsing = 1; } break;

        default: parseState->errorIsPrev = 1; jk_error_parse_accept_or3(parseState, dictState, @"a \"STRING\"", @"a comma", @"a '}'"); stopParsing = 1; break;
      }
    }

    if(JK_EXPECT_T(stopParsing == 0)) {
      if(JK_EXPECT_T((stopParsing = jk_parse_next_token(parseState)) == 0)) { if(JK_EXPECT_F(parseState->token.type != JKTokenTypeSeparator)) { parseState->errorIsPrev = 1; jk_error(parseState, @"Expected ':'."); stopParsing = 1; } }
    }

    if((JK_EXPECT_T(stopParsing == 0)) && (JK_EXPECT_T((stopParsing = jk_parse_next_token(parseState)) == 0))) {
      switch(parseState->token.type) {
        case JKTokenTypeNumber:
        case JKTokenTypeString:
        case JKTokenTypeTrue:
        case JKTokenTypeFalse:
        case JKTokenTypeNull:
        case JKTokenTypeArrayBegin:
        case JKTokenTypeObjectBegin:
          if(JK_EXPECT_F((dictState & JKParseAcceptValue)           == 0))    { parseState->errorIsPrev = 1; jk_error(parseState, @"Unexpected value.");               stopParsing = 1; break; }
          if(JK_EXPECT_F((object = jk_object_for_token(parseState)) == NULL)) {                              jk_error(parseState, @"Internal error: Object == NULL."); stopParsing = 1; break; } else { parseState->objectStack.objects[objectStackIndex] = object; dictState = JKParseAcceptCommaOrEnd; }
          break;
        default: parseState->errorIsPrev = 1; jk_error_parse_accept_or3(parseState, dictState, @"a value", @"a comma", @"a '}'"); stopParsing = 1; break;
      }
    }
  }

  if(JK_EXPECT_F(parsedDictionary == NULL)) { size_t idx = 0UL; for(idx = startingObjectIndex; idx < parseState->objectStack.index; idx++) { if(parseState->objectStack.keys[idx] != NULL) { CFRelease(parseState->objectStack.keys[idx]); parseState->objectStack.keys[idx] = NULL; } if(parseState->objectStack.objects[idx] != NULL) { CFRelease(parseState->objectStack.objects[idx]); parseState->objectStack.objects[idx] = NULL; } } }
#if !defined(NS_BLOCK_ASSERTIONS)
  else { size_t idx = 0UL; for(idx = startingObjectIndex; idx < parseState->objectStack.index; idx++) { parseState->objectStack.objects[idx] = NULL; parseState->objectStack.keys[idx] = NULL; } }
#endif

  parseState->objectStack.index = startingObjectIndex;
  return(parsedDictionary);
}

static id json_parse_it(JKParseState *parseState) {
  id  parsedObject = NULL;
  int stopParsing  = 0;

  while((JK_EXPECT_T(stopParsing == 0)) && (JK_EXPECT_T(parseState->atIndex < parseState->stringBuffer.bytes.length))) {
    if((JK_EXPECT_T(stopParsing == 0)) && (JK_EXPECT_T((stopParsing = jk_parse_next_token(parseState)) == 0))) {
      switch(parseState->token.type) {
        case JKTokenTypeArrayBegin:
        case JKTokenTypeObjectBegin: parsedObject = [(id)jk_object_for_token(parseState) autorelease]; stopParsing = 1; break;
        default:                     jk_error(parseState, @"Expected either '[' or '{'.");             stopParsing = 1; break;
      }
    }
  }

  NSCParameterAssert((parseState->objectStack.index == 0) && (JK_AT_STRING_PTR(parseState) <= JK_END_STRING_PTR(parseState)));

  if((parsedObject == NULL) && (JK_AT_STRING_PTR(parseState) == JK_END_STRING_PTR(parseState))) { jk_error(parseState, @"Reached the end of the buffer."); }
  if(parsedObject == NULL) { jk_error(parseState, @"Unable to parse JSON."); }

  if((parsedObject != NULL) && (JK_AT_STRING_PTR(parseState) < JK_END_STRING_PTR(parseState))) {
    jk_parse_skip_whitespace(parseState);
    if((parsedObject != NULL) && ((parseState->parseOptionFlags & JKParseOptionPermitTextAfterValidJSON) == 0) && (JK_AT_STRING_PTR(parseState) < JK_END_STRING_PTR(parseState))) {
      jk_error(parseState, @"A valid JSON object was parsed but there were additional non-white-space characters remaining.");
      parsedObject = NULL;
    }
  }

  return(parsedObject);
}

@implementation JSONDecoder

static Class            _jk_NSNumberClass;
static NSNumberAllocImp _jk_NSNumberAllocImp;
static NSNumberInitWithUnsignedLongLongImp _jk_NSNumberInitWithUnsignedLongLongImp;

+ (void)load
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  
  _jk_NSNumberClass = [NSNumber class];
  _jk_NSNumberAllocImp = (NSNumberAllocImp)[NSNumber methodForSelector:@selector(alloc)];
  
  // Hacktacular.  Need to do it this way due to the nature of class clusters.
  id temp_NSNumber = [NSNumber alloc];
  _jk_NSNumberInitWithUnsignedLongLongImp = (NSNumberInitWithUnsignedLongLongImp)[temp_NSNumber methodForSelector:@selector(initWithUnsignedLongLong:)];
  [[temp_NSNumber init] release];
  temp_NSNumber = NULL;
  
  [pool release]; pool = NULL;
}

+ (id)decoder
{
  return([self decoderWithParseOptions:JKParseOptionStrict]);
}

+ (id)decoderWithParseOptions:(JKParseOptionFlags)parseOptionFlags
{
  return([[[self alloc] initWithParseOptions:parseOptionFlags] autorelease]);
}

- (id)init
{
  return([self initWithParseOptions:JKParseOptionStrict]);
}

- (id)initWithParseOptions:(JKParseOptionFlags)parseOptionFlags
{
  if((self = [super init]) == NULL) { return(NULL); }

  if(parseOptionFlags & ~JKParseOptionValidFlags) { [self autorelease]; [NSException raise:NSInvalidArgumentException format:@"Invalid parse options."]; }

  if((parseState = (JKParseState *)calloc(1UL, sizeof(JKParseState))) == NULL) { goto errorExit; }

  parseState->parseOptionFlags = parseOptionFlags;
  
  parseState->token.tokenBuffer.roundSizeUpToMultipleOf = 4096UL;
  parseState->objectStack.roundSizeUpToMultipleOf       = 2048UL;

  parseState->objCImpCache.NSNumberClass                    = _jk_NSNumberClass;
  parseState->objCImpCache.NSNumberAlloc                    = _jk_NSNumberAllocImp;
  parseState->objCImpCache.NSNumberInitWithUnsignedLongLong = _jk_NSNumberInitWithUnsignedLongLongImp;
  
  parseState->cache.count = JK_CACHE_SLOTS;
  if((parseState->cache.items = (JKTokenCacheItem *)calloc(1UL, sizeof(JKTokenCacheItem) * parseState->cache.count)) == NULL) { goto errorExit; }

  return(self);

 errorExit:
  if(self) { [self autorelease]; self = NULL; }
  return(NULL);
}

- (void)dealloc
{
  if(parseState != NULL) {
    jk_managedBuffer_release(&parseState->token.tokenBuffer);
    jk_objectStack_release(&parseState->objectStack);

    [self clearCache];
    if(parseState->cache.items != NULL) { free(parseState->cache.items); parseState->cache.items = NULL; }

    free(parseState); parseState = NULL;
  }
  [super dealloc];
}

- (void)clearCache
{
  if(JK_EXPECT_T(parseState != NULL) && JK_EXPECT_T(parseState->cache.items != NULL)) {
    size_t idx = 0UL;
    for(idx = 0UL; idx < parseState->cache.count; idx++) {
      if(JK_EXPECT_T(parseState->cache.items[idx].object != NULL)) { CFRelease(parseState->cache.items[idx].object); parseState->cache.items[idx].object = NULL; }
      if(JK_EXPECT_T(parseState->cache.items[idx].bytes  != NULL)) { free(parseState->cache.items[idx].bytes);       parseState->cache.items[idx].bytes  = NULL; }
#ifndef NS_BLOCK_ASSERTIONS
      memset(&parseState->cache.items[idx], 0, sizeof(JKTokenCacheItem));
#endif
    }
  }
}

- (id)parseUTF8String:(const unsigned char *)string length:(size_t)length
{
  return([self parseUTF8String:string length:length error:NULL]);
}

// This needs to be completely rewritten.
- (id)parseUTF8String:(const unsigned char *)string length:(size_t)length error:(NSError **)error
{
  if(parseState == NULL) { [NSException raise:NSInternalInconsistencyException format:@"parseState is NULL."];          } 
  if(string     == NULL) { [NSException raise:NSInvalidArgumentException       format:@"The string argument is NULL."]; } 
  if((error     != NULL) && (*error != NULL)) { *error = NULL; }

  parseState->stringBuffer.bytes.ptr    = string;
  parseState->stringBuffer.bytes.length = length;
  parseState->atIndex                   = 0UL;
  parseState->lineNumber                = 1UL;
  parseState->lineStartIndex            = 0UL;
  parseState->prev_atIndex              = 0UL;
  parseState->prev_lineNumber           = 1UL;
  parseState->prev_lineStartIndex       = 0UL;
  parseState->error                     = NULL;
  parseState->errorIsPrev               = 0;
  
  unsigned char stackTokenBuffer[JK_TOKENBUFFER_SIZE] JK_ALIGNED(64);
  jk_managedBuffer_setToStackBuffer(&parseState->token.tokenBuffer, stackTokenBuffer, sizeof(stackTokenBuffer));

  void       *stackObjects [JK_STACK_OBJS] JK_ALIGNED(64);
  void       *stackKeys    [JK_STACK_OBJS] JK_ALIGNED(64);
  CFHashCode  stackCFHashes[JK_STACK_OBJS] JK_ALIGNED(64);
  jk_objectStack_setToStackBuffer(&parseState->objectStack, stackObjects, stackKeys, stackCFHashes, JK_STACK_OBJS);

  id parsedJSON = json_parse_it(parseState);

  if((error != NULL) && (parseState->error != NULL)) { *error = parseState->error; }

  jk_managedBuffer_release(&parseState->token.tokenBuffer);
  jk_objectStack_release(&parseState->objectStack);

  parseState->stringBuffer.bytes.ptr    = NULL;
  parseState->stringBuffer.bytes.length = 0UL;
  parseState->atIndex                   = 0UL;
  parseState->lineNumber                = 1UL;
  parseState->lineStartIndex            = 0UL;
  parseState->prev_atIndex              = 0UL;
  parseState->prev_lineNumber           = 1UL;
  parseState->prev_lineStartIndex       = 0UL;
  parseState->error                     = NULL;
  parseState->errorIsPrev               = 0;

  return(parsedJSON);
}

- (id)parseJSONData:(NSData *)jsonData
{
  return([self parseJSONData:jsonData error:NULL]);
}

- (id)parseJSONData:(NSData *)jsonData error:(NSError **)error
{
  if(jsonData == NULL) { [NSException raise:NSInvalidArgumentException format:@"The jsonData argument is NULL."]; } 
  return([self parseUTF8String:(const unsigned char *)[jsonData bytes] length:[jsonData length] error:error]);
}

@end

@implementation NSString (JSONKit)

- (id)objectFromJSONString
{
  return([self objectFromJSONStringWithParseOptions:JKParseOptionStrict error:NULL]);
}

- (id)objectFromJSONStringWithParseOptions:(JKParseOptionFlags)parseOptionFlags
{
  return([self objectFromJSONStringWithParseOptions:parseOptionFlags error:NULL]);
}

- (id)objectFromJSONStringWithParseOptions:(JKParseOptionFlags)parseOptionFlags error:(NSError **)error
{
  const unsigned char *utf8String = (const unsigned char *)[self UTF8String];
  if(utf8String == NULL) { return(NULL); }
  size_t               utf8Length = strlen((const char *)utf8String);

  return([[JSONDecoder decoderWithParseOptions:parseOptionFlags] parseUTF8String:utf8String length:utf8Length error:error]);
}

@end

@implementation NSData (JSONKit)

- (id)objectFromJSONData
{
  return([self objectFromJSONDataWithParseOptions:JKParseOptionStrict error:NULL]);
}

- (id)objectFromJSONDataWithParseOptions:(JKParseOptionFlags)parseOptionFlags
{
  return([self objectFromJSONDataWithParseOptions:parseOptionFlags error:NULL]);
}

- (id)objectFromJSONDataWithParseOptions:(JKParseOptionFlags)parseOptionFlags error:(NSError **)error
{
  return([[JSONDecoder decoderWithParseOptions:parseOptionFlags] parseJSONData:self error:error]);
}

@end



static void jk_encode_error(JKEncodeState *encodeState, NSString *format, ...) {
  NSCParameterAssert((encodeState != NULL) && (format != NULL));

  va_list varArgsList;
  va_start(varArgsList, format);
  NSString *formatString = [[[NSString alloc] initWithFormat:format arguments:varArgsList] autorelease];
  va_end(varArgsList);

  if(encodeState->error == NULL) {
    encodeState->error = [NSError errorWithDomain:@"JKErrorDomain" code:-1L userInfo:
                                   [NSDictionary dictionaryWithObjectsAndKeys:
                                                                              formatString, NSLocalizedDescriptionKey,
                                                                              NULL]];
  }
}



static int jk_encode_printf(JKEncodeState *encodeState, const char *format, ...) {
  va_list varArgsList;
  va_start(varArgsList, format);
  va_end(varArgsList);

  if(encodeState->stringBuffer.bytes.length < encodeState->atIndex) { jk_encode_error(encodeState, @"Internal inconsistency error: atIndex > buffer length. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); return(1); }
  if((encodeState->stringBuffer.bytes.length - encodeState->atIndex) < 1024L) { if(jk_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + 4096UL) == NULL) { jk_encode_error(encodeState, @"Unable to resize temporary buffer."); return(1); } }

  char    *atPtr     = (char *)encodeState->stringBuffer.bytes.ptr    + encodeState->atIndex;
  ssize_t  remaining =         encodeState->stringBuffer.bytes.length - encodeState->atIndex;

  int printfAdded = vsnprintf(atPtr, remaining, format, varArgsList);

  while(printfAdded > remaining) {
    if(jk_managedBuffer_resize(&encodeState->stringBuffer, encodeState->stringBuffer.bytes.length + (printfAdded * 2UL) + 1024UL) == NULL) { jk_encode_error(encodeState, @"Unable to resize temporary buffer."); return(1); }
    remaining = encodeState->stringBuffer.bytes.length - encodeState->atIndex;
    printfAdded = vsnprintf(atPtr, remaining, format, varArgsList);
  }

  encodeState->atIndex += printfAdded;
  return(0);
}

static int jk_encode_write(JKEncodeState *encodeState, const char *format) {
#ifndef NS_BLOCK_ASSERTIONS
  if(JK_EXPECT_F(encodeState->stringBuffer.bytes.length < encodeState->atIndex)) { jk_encode_error(encodeState, @"Internal inconsistency error: atIndex > buffer length. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); return(1); }
#endif
  if(JK_EXPECT_F((encodeState->stringBuffer.bytes.length - encodeState->atIndex) < 1024L)) { if(jk_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + 4096UL) == NULL) { jk_encode_error(encodeState, @"Unable to resize temporary buffer."); return(1); } }

  char    *atPtr     = (char *)encodeState->stringBuffer.bytes.ptr    + encodeState->atIndex;
  ssize_t  remaining =         encodeState->stringBuffer.bytes.length - encodeState->atIndex;

  ssize_t idx = 0L, added = 0L;
  for(added = 0L, idx = 0L; format[added] != 0; added++) { if(JK_EXPECT_T(idx < remaining)) { atPtr[idx++] = format[added]; } }

  if(JK_EXPECT_F(added > remaining)) {
    if(JK_EXPECT_F(jk_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + added + 1024UL) == NULL)) { jk_encode_error(encodeState, @"Unable to resize temporary buffer."); return(1); }
    for(added = 0L, idx = 0L; format[added] != 0; added++) { if(JK_EXPECT_T(idx < remaining)) { atPtr[idx++] = format[added]; } }
  }

  atPtr[idx] = 0;
  encodeState->atIndex += added;
  return(0);
}

static int jk_encode_write1(JKEncodeState *encodeState, const char *format) {
  if((encodeState->atIndex + 4UL) < encodeState->stringBuffer.bytes.length) { encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = format[0]; }
  else { if(JK_EXPECT_F(jk_encode_write(encodeState, format))) { return(1); } }
  return(0);
}

static int jk_encode_writen(JKEncodeState *encodeState, const char *format, size_t length) {
  if(JK_EXPECT_F((encodeState->stringBuffer.bytes.length - encodeState->atIndex) < (length + 4UL))) { if(jk_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + 4096UL + length) == NULL) { jk_encode_error(encodeState, @"Unable to resize temporary buffer."); return(1); } }
  memcpy(encodeState->stringBuffer.bytes.ptr + encodeState->atIndex, format, length);
  encodeState->atIndex += length;
  return(0);
}

static int jk_encode_add_atom_to_buffer(JKEncodeState *encodeState, void *objectPtr) {
  NSCParameterAssert((encodeState != NULL) && (objectPtr != NULL));
  NSCParameterAssert(encodeState->atIndex < encodeState->stringBuffer.bytes.length);

  id  object  = (id)objectPtr;
  int isClass = JKClassUnknown;

       if(object->isa == encodeState->fastClassLookup.stringClass)     { isClass = JKClassString;     }
  else if(object->isa == encodeState->fastClassLookup.numberClass)     { isClass = JKClassNumber;     }
  else if(object->isa == encodeState->fastClassLookup.dictionaryClass) { isClass = JKClassDictionary; }
  else if(object->isa == encodeState->fastClassLookup.arrayClass)      { isClass = JKClassArray;      }
  else if(object->isa == encodeState->fastClassLookup.nullClass)       { isClass = JKClassNull;       }
  else {
         if([object isKindOfClass:[NSString     class]]) { encodeState->fastClassLookup.stringClass     = object->isa; isClass = JKClassString;     }
    else if([object isKindOfClass:[NSNumber     class]]) { encodeState->fastClassLookup.numberClass     = object->isa; isClass = JKClassNumber;     }
    else if([object isKindOfClass:[NSDictionary class]]) { encodeState->fastClassLookup.dictionaryClass = object->isa; isClass = JKClassDictionary; }
    else if([object isKindOfClass:[NSArray      class]]) { encodeState->fastClassLookup.arrayClass      = object->isa; isClass = JKClassArray;      }
    else if([object isKindOfClass:[NSNull       class]]) { encodeState->fastClassLookup.nullClass       = object->isa; isClass = JKClassNull;       }
    else { jk_encode_error(encodeState, @"Unable to serialize object class %@.", NSStringFromClass([object class])); return(1); }
  }

  switch(isClass) {
    case JKClassString:
      {
        {
          const unsigned char *cStringPtr = (const unsigned char *)CFStringGetCStringPtr((CFStringRef)object, kCFStringEncodingMacRoman);
          if(cStringPtr != NULL) {
            size_t               utf8Idx = 0UL, startingAtIndex = encodeState->atIndex;
            const unsigned char *utf8String = cStringPtr;

            CFIndex stringLength = CFStringGetLength((CFStringRef)object);
            if(JK_EXPECT_F(((encodeState->atIndex + (stringLength * 2UL) + 256UL) > encodeState->stringBuffer.bytes.length)) && JK_EXPECT_F((jk_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + (stringLength * 2UL) + 1024UL) == NULL))) { jk_encode_error(encodeState, @"Unable to resize temporary buffer."); return(1); }

            encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\"';
            for(utf8Idx = 0UL; utf8String[utf8Idx] != 0; utf8Idx++) {
              NSCParameterAssert(((&encodeState->stringBuffer.bytes.ptr[encodeState->atIndex]) - encodeState->stringBuffer.bytes.ptr) < (ssize_t)encodeState->stringBuffer.bytes.length);
              NSCParameterAssert(encodeState->atIndex < encodeState->stringBuffer.bytes.length);
              if(JK_EXPECT_F(utf8String[utf8Idx] >= 0x80)) { encodeState->atIndex = startingAtIndex; goto slowUTF8Path; }
              if(JK_EXPECT_F(utf8String[utf8Idx] <  0x20)) {
                switch(utf8String[utf8Idx]) {
                  case '\b': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 'b'; break;
                  case '\f': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 'f'; break;
                  case '\n': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 'n'; break;
                  case '\r': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 'r'; break;
                  case '\t': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 't'; break;
                  default: if(jk_encode_printf(encodeState, "\\u%4.4x", utf8String[utf8Idx])) { return(1); } break;
                }
              } else {
                if(JK_EXPECT_F(utf8String[utf8Idx] == '\"') || JK_EXPECT_F(utf8String[utf8Idx] == '\\')) { encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; }
                encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = utf8String[utf8Idx];
              }
            }
            NSCParameterAssert((encodeState->atIndex + 1UL) < encodeState->stringBuffer.bytes.length);
            encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\"';
            return(0);
          }
        }

      slowUTF8Path:
        {
          CFIndex stringLength        = CFStringGetLength((CFStringRef)object);
          CFIndex maxStringUTF8Length = CFStringGetMaximumSizeForEncoding(stringLength, kCFStringEncodingUTF8) + 32L;
        
          if(((size_t)maxStringUTF8Length > encodeState->utf8ConversionBuffer.bytes.length) && (jk_managedBuffer_resize(&encodeState->utf8ConversionBuffer, maxStringUTF8Length + 1024UL) == NULL)) { jk_encode_error(encodeState, @"Unable to resize temporary buffer."); return(1); }
        
          CFIndex usedBytes = 0L, convertedCount = 0L;
          convertedCount = CFStringGetBytes((CFStringRef)object, CFRangeMake(0L, stringLength), kCFStringEncodingUTF8, '?', NO, encodeState->utf8ConversionBuffer.bytes.ptr, encodeState->utf8ConversionBuffer.bytes.length - 16L, &usedBytes);
          if(JK_EXPECT_F(convertedCount != stringLength) || JK_EXPECT_F(usedBytes < 0L)) { jk_encode_error(encodeState, @"An error occured converting the contents of a NSString to UTF8."); return(1); }
        
          if(JK_EXPECT_F((encodeState->atIndex + (maxStringUTF8Length * 2UL) + 256UL) > encodeState->stringBuffer.bytes.length) && JK_EXPECT_F(jk_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + (maxStringUTF8Length * 2UL) + 1024UL) == NULL)) { jk_encode_error(encodeState, @"Unable to resize temporary buffer."); return(1); }
        
          const unsigned char *utf8String = encodeState->utf8ConversionBuffer.bytes.ptr;
        
          size_t utf8Idx = 0UL;
          encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\"';
          for(utf8Idx = 0UL; utf8Idx < (size_t)usedBytes; utf8Idx++) {
            NSCParameterAssert(((&encodeState->stringBuffer.bytes.ptr[encodeState->atIndex]) - encodeState->stringBuffer.bytes.ptr) < (ssize_t)encodeState->stringBuffer.bytes.length);
            NSCParameterAssert(encodeState->atIndex < encodeState->stringBuffer.bytes.length);
            NSCParameterAssert((CFIndex)utf8Idx < usedBytes);
            if(JK_EXPECT_F(utf8String[utf8Idx] < 0x20)) {
              switch(utf8String[utf8Idx]) {
                case '\b': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 'b'; break;
                case '\f': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 'f'; break;
                case '\n': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 'n'; break;
                case '\r': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 'r'; break;
                case '\t': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 't'; break;
                default: if(jk_encode_printf(encodeState, "\\u%4.4x", utf8String[utf8Idx])) { return(1); } break;
              }
            } else {
              if(JK_EXPECT_F(utf8String[utf8Idx] >= 0x80) && (encodeState->serializeOptionFlags & JKSerializeOptionEscapeUnicode)) {
                const unsigned char *nextValidCharacter = NULL;
                UTF32                u32ch              = 0UL;
                ConversionResult     result;

                if(JK_EXPECT_F((result = ConvertSingleCodePointInUTF8(&utf8String[utf8Idx], &utf8String[usedBytes], (UTF8 const **)&nextValidCharacter, &u32ch)) != conversionOK)) { jk_encode_error(encodeState, @"Error converting UTF8."); return(1); }
                else {
                  utf8Idx = (nextValidCharacter - utf8String) - 1L;
                  if(u32ch <= 0xffff) { if(jk_encode_printf(encodeState, "\\u%4.4x", u32ch))                                                        { return(1); } }
                  else                { if(jk_encode_printf(encodeState, "\\u%4.4x\\u%4.4x", (0xd7c0 + (u32ch >> 10)), (0xdc00 + (u32ch & 0x3ff)))) { return(1); } }
                }
              } else {
                if((utf8String[utf8Idx] == '\"') || (utf8String[utf8Idx] == '\\')) { encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; }
                encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = utf8String[utf8Idx];
              }
            }
          }
          NSCParameterAssert((encodeState->atIndex + 1UL) < encodeState->stringBuffer.bytes.length);
          encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\"';
          return(0);
        }
      }
      break;

    case JKClassNumber:
      {
        if(object == (id)kCFBooleanTrue) { return(jk_encode_writen(encodeState, "true", 4UL)); break; } else if(object == (id)kCFBooleanFalse) { return(jk_encode_writen(encodeState, "false", 5UL)); break; }

        const char         *objCType = [object objCType];
        char                anum[256], *aptr = &anum[255];
        int                 isNegative = 0;
        unsigned long long  ullv;
        long long           llv;

        switch(objCType[0]) {
          case 'c': case 'i': case 's': case 'l': case 'q': 
            if(JK_EXPECT_T(CFNumberGetValue((CFNumberRef)object, kCFNumberLongLongType, &llv)))  {
              if(llv < 0LL)  { llv = -llv; isNegative = 1; }
              if(JK_EXPECT_F(llv < 10LL)) { *--aptr = llv + '0';        } else { while(JK_EXPECT_T(llv > 0LL)) { *--aptr = (llv % 10LL) + '0'; llv /= 10LL; NSCParameterAssert(aptr > anum); } }
              if(isNegative) { *--aptr = '-';              }
              NSCParameterAssert(aptr > anum);
              return(jk_encode_writen(encodeState, aptr, &anum[255] - aptr));
            } else { jk_encode_error(encodeState, @"Unable to get scalar value from number object."); return(1); }
          case 'C': case 'I': case 'S': case 'L': case 'Q': case 'B':
            if(JK_EXPECT_T(CFNumberGetValue((CFNumberRef)object, kCFNumberLongLongType, &ullv))) {
              if(JK_EXPECT_F(ullv < 10ULL)) { *--aptr = ullv + '0'; } else { while(JK_EXPECT_T(ullv > 0ULL)) { *--aptr = (ullv % 10ULL) + '0'; ullv /= 10ULL; NSCParameterAssert(aptr > anum); } }
              NSCParameterAssert(aptr > anum);
              return(jk_encode_writen(encodeState, aptr, &anum[255] - aptr));
            } else { jk_encode_error(encodeState, @"Unable to get scalar value from number object."); return(1); }
          case 'f': case 'd':
            {
              double dv;
              if(JK_EXPECT_T(CFNumberGetValue((CFNumberRef)object, kCFNumberDoubleType, &dv))) {
                if(JK_EXPECT_F(!isfinite(dv))) { jk_encode_error(encodeState, @"Floating point values must be finite.  JSON does not support NaN or Infinity."); return(1); }
                return(jk_encode_printf(encodeState, "%.17g", dv));
              }
            }
            break;
          default: jk_encode_error(encodeState, @"NSNumber conversion error, unknown type.  Type: '%c' / 0x%2.2x", objCType[0], objCType[0]); return(1); break;
        }
      }
      break;
    
    case JKClassArray:
      {
        int     printComma = 0;
        CFIndex arrayCount = CFArrayGetCount((CFArrayRef)object), idx = 0L;
        if(jk_encode_write1(encodeState, "[")) { return(1); }
        if(arrayCount > 1020L) {
          for(id arrayObject in object) { if(printComma) { if(jk_encode_write1(encodeState, ",")) { return(1); } } printComma = 1; if(jk_encode_add_atom_to_buffer(encodeState, arrayObject)) { return(1); } }
        } else {
          void *objects[1024];
          CFArrayGetValues((CFArrayRef)object, CFRangeMake(0L, arrayCount), (const void **)objects);
          for(idx = 0L; idx < arrayCount; idx++) { if(printComma) { if(jk_encode_write1(encodeState, ",")) { return(1); } } printComma = 1; if(jk_encode_add_atom_to_buffer(encodeState, objects[idx])) { return(1); } }
        }
        if(jk_encode_write1(encodeState, "]")) { return(1); }
      }
      break;

    case JKClassDictionary:
      {
        int     printComma      = 0;
        CFIndex dictionaryCount = CFDictionaryGetCount((CFDictionaryRef)object), idx = 0L;

        if(JK_EXPECT_F(jk_encode_write1(encodeState, "{"))) { return(1); }
        if(JK_EXPECT_F(dictionaryCount > 1020L)) {
          for(id keyObject in object) {
            if(printComma) { if(JK_EXPECT_F(jk_encode_write1(encodeState, ","))) { return(1); } }
            printComma = 1;
            if(JK_EXPECT_F((keyObject->isa != encodeState->fastClassLookup.stringClass)) && JK_EXPECT_F(([keyObject isKindOfClass:[NSString class]] == NO))) { jk_encode_error(encodeState, @"Key must be a string object."); return(1); }
            if(JK_EXPECT_F(jk_encode_add_atom_to_buffer(encodeState, keyObject)))                                                        { return(1); }
            if(JK_EXPECT_F(jk_encode_write1(encodeState, ":")))                                                                          { return(1); }
            if(JK_EXPECT_F(jk_encode_add_atom_to_buffer(encodeState, (void *)CFDictionaryGetValue((CFDictionaryRef)object, keyObject)))) { return(1); }
          }
        } else {
          void *keys[1024], *objects[1024];
          CFDictionaryGetKeysAndValues((CFDictionaryRef)object, (const void **)keys, (const void **)objects);
          for(idx = 0L; idx < dictionaryCount; idx++) {
            if(JK_EXPECT_F(printComma)) { if(JK_EXPECT_F(jk_encode_write1(encodeState, ","))) { return(1); } }
            printComma = 1;
            if(JK_EXPECT_F((((id)keys[idx])->isa != encodeState->fastClassLookup.stringClass)) && JK_EXPECT_F(([(id)keys[idx] isKindOfClass:[NSString class]] == NO))) { jk_encode_error(encodeState, @"Key must be a string object."); return(1); }
            if(JK_EXPECT_F(jk_encode_add_atom_to_buffer(encodeState, keys[idx])))    { return(1); }
            if(JK_EXPECT_F(jk_encode_write1(encodeState, ":")))                      { return(1); }
            if(JK_EXPECT_F(jk_encode_add_atom_to_buffer(encodeState, objects[idx]))) { return(1); }
          }
        }
        if(JK_EXPECT_F(jk_encode_write1(encodeState, "}"))) { return(1); }
      }
      break;

    case JKClassNull: if(JK_EXPECT_F(jk_encode_writen(encodeState, "null", 4UL))) { return(1); } break;

    default: jk_encode_error(encodeState, @"Unable to serialize object class %@.", NSStringFromClass([object class])); return(1); break;
  }

  return(0);
}


static id jk_encode(void *object, JKSerializeOptionFlags optionFlags, JKEncodeAsType encodeAs, NSError **error) {
  NSCParameterAssert(object != NULL);
  id returnObject = NULL;

  if((error != NULL) && (*error != NULL)) { *error = NULL; }

  JKEncodeState encodeState;
  memset(&encodeState, 0, sizeof(JKEncodeState));

  encodeState.serializeOptionFlags = optionFlags;

  encodeState.stringBuffer.roundSizeUpToMultipleOf         = (1024UL * 32UL);
  encodeState.utf8ConversionBuffer.roundSizeUpToMultipleOf = 4096UL;

  unsigned char stackJSONBuffer[JK_JSONBUFFER_SIZE] JK_ALIGNED(64);
  jk_managedBuffer_setToStackBuffer(&encodeState.stringBuffer, stackJSONBuffer, sizeof(stackJSONBuffer));

  unsigned char stackUTF8Buffer[JK_UTF8BUFFER_SIZE] JK_ALIGNED(64);
  jk_managedBuffer_setToStackBuffer(&encodeState.utf8ConversionBuffer, stackUTF8Buffer, sizeof(stackUTF8Buffer));

  if(jk_encode_add_atom_to_buffer(&encodeState, object) == 0) {
    switch(encodeAs) {
      case JKEncodeAsData: {
        NSData *jsonData = NULL;
        if((encodeState.stringBuffer.flags & JKManagedBufferMustFree) == 0) {
          if((jsonData = [(NSData *)CFDataCreate(NULL, encodeState.stringBuffer.bytes.ptr, encodeState.atIndex) autorelease]) == NULL) { jk_encode_error(&encodeState, @"Unable to create NSData object"); }
        } else {
          if((encodeState.stringBuffer.bytes.ptr = (unsigned char *)reallocf(encodeState.stringBuffer.bytes.ptr, encodeState.atIndex)) != NULL) {
            if((jsonData = [(NSData *)CFDataCreateWithBytesNoCopy(NULL, encodeState.stringBuffer.bytes.ptr, encodeState.atIndex, NULL) autorelease]) == NULL) { jk_encode_error(&encodeState, @"Unable to create NSData object"); }
          }
          if((jsonData != NULL) || (encodeState.stringBuffer.bytes.ptr == NULL)) {
            encodeState.stringBuffer.flags        &= ~JKManagedBufferMustFree;
            encodeState.stringBuffer.bytes.ptr     = NULL;
            encodeState.stringBuffer.bytes.length  = 0UL;
          }
        }
        returnObject = jsonData;
      }
        break;

      case JKEncodeAsString: {
        NSString *jsonString = NULL;
        if((encodeState.stringBuffer.flags & JKManagedBufferMustFree) == 0) {
          if((jsonString = [(NSString *)CFStringCreateWithBytes(NULL, (const UInt8 *)encodeState.stringBuffer.bytes.ptr, (CFIndex)encodeState.atIndex, kCFStringEncodingUTF8, NO) autorelease]) == NULL) { jk_encode_error(&encodeState, @"Unable to create NSString object"); }
        } else {
          if((encodeState.stringBuffer.bytes.ptr = (unsigned char *)reallocf(encodeState.stringBuffer.bytes.ptr, encodeState.atIndex + 256UL)) != NULL) {
            encodeState.stringBuffer.bytes.ptr[encodeState.atIndex + 1UL] = 0;
            if((jsonString = [(NSString *)CFStringCreateWithBytesNoCopy(NULL, (const UInt8 *)encodeState.stringBuffer.bytes.ptr, (CFIndex)encodeState.atIndex, kCFStringEncodingUTF8, NO, NULL) autorelease]) == NULL) { jk_encode_error(&encodeState, @"Unable to create NSString object"); }
          }
          if((jsonString != NULL) || (encodeState.stringBuffer.bytes.ptr == NULL)) {
            encodeState.stringBuffer.flags        &= ~JKManagedBufferMustFree;
            encodeState.stringBuffer.bytes.ptr     = NULL;
            encodeState.stringBuffer.bytes.length  = 0UL;
          }
        }
        returnObject = jsonString;
      }
        break;

      default: jk_encode_error(&encodeState, @"Unknown encode as type."); break;
    }
  }
  if((error != NULL) && (encodeState.error != NULL)) { *error = encodeState.error; }

  jk_managedBuffer_release(&encodeState.stringBuffer);
  jk_managedBuffer_release(&encodeState.utf8ConversionBuffer);

  return(returnObject);
}


@implementation NSArray (JSONKit)

- (NSData *)JSONData
{
  return([self JSONDataWithOptions:JKSerializeOptionNone error:NULL]);
}

- (NSData *)JSONDataWithOptions:(JKSerializeOptionFlags)serializeOptions error:(NSError **)error
{
  return(jk_encode(self, serializeOptions, JKEncodeAsData, error));
}

- (NSString *)JSONString
{
  return([self JSONStringWithOptions:JKSerializeOptionNone error:NULL]);
}

- (NSString *)JSONStringWithOptions:(JKSerializeOptionFlags)serializeOptions error:(NSError **)error
{
  return(jk_encode(self, serializeOptions, JKEncodeAsString, error));
}

@end

@implementation NSDictionary (JSONKit)

- (NSData *)JSONData
{
  return([self JSONDataWithOptions:JKSerializeOptionNone error:NULL]);
}

- (NSData *)JSONDataWithOptions:(JKSerializeOptionFlags)serializeOptions error:(NSError **)error
{
  return(jk_encode(self, serializeOptions, JKEncodeAsData, error));
}

- (NSString *)JSONString
{
  return([self JSONStringWithOptions:JKSerializeOptionNone error:NULL]);
}

- (NSString *)JSONStringWithOptions:(JKSerializeOptionFlags)serializeOptions error:(NSError **)error
{
  return(jk_encode(self, serializeOptions, JKEncodeAsString, error));
}

@end
