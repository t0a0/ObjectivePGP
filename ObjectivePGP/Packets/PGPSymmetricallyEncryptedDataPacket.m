//
//  Copyright (c) Marcin Krzyżanowski. All rights reserved.
//
//  THIS SOURCE CODE AND ANY ACCOMPANYING DOCUMENTATION ARE PROTECTED BY
//  INTERNATIONAL COPYRIGHT LAW. USAGE IS BOUND TO THE LICENSE AGREEMENT.
//  This notice may not be removed from this file.
//
//  Parse only

#import "PGPSymmetricallyEncryptedDataPacket.h"
#import "PGPCryptoCFB.h"
#import "PGPCryptoUtils.h"
#import "PGPPublicKeyPacket.h"
#import "PGPPacket+Private.h"
#import "PGPMacros+Private.h"
#import "PGPCompressedPacket.h"
#import "PGPFoundation.h"

#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>

#import <openssl/aes.h>
#import <openssl/blowfish.h>
#import <openssl/camellia.h>
#import <openssl/cast.h>
#import <openssl/des.h>
#import <openssl/idea.h>
#import <openssl/sha.h>

NS_ASSUME_NONNULL_BEGIN

@implementation PGPSymmetricallyEncryptedDataPacket

- (NSUInteger)parsePacketBody:(NSData *)packetBody error:(NSError * __autoreleasing _Nullable *)error {
    NSUInteger position = [super parsePacketBody:packetBody error:error];

    self.encryptedData = packetBody;

    return position;
}

- (nullable NSData *)export:(NSError * __autoreleasing _Nullable *)error {
    if (!self.encryptedData) {
        if (error) {
            *error = [NSError errorWithDomain:PGPErrorDomain code:PGPErrorGeneral userInfo:@{ NSLocalizedDescriptionKey: @"Unable to export packet. Missing encrypted data." }];
        }
        return nil;
    }

    return self.encryptedData;
}

- (NSArray<PGPPacket *> *)readPacketsFromData:(NSData *)keyringData offset:(NSUInteger)offsetPosition mdcLength:(nullable NSUInteger *)mdcLength {
    let accumulatedPackets = [NSMutableArray<PGPPacket *> array];
    if (mdcLength) { *mdcLength = 0; }
    NSInteger offset = offsetPosition;
    NSUInteger nextPacketOffset = 0;
    while (offset < (NSInteger)keyringData.length) {
        let _Nullable packet = [PGPPacketFactory packetWithData:keyringData offset:offset nextPacketOffset:&nextPacketOffset];
        if (packet) {
            [accumulatedPackets addObject:packet];
            if (packet.tag != PGPModificationDetectionCodePacketTag) {
                if (mdcLength) {
                    *mdcLength += nextPacketOffset;
                }
            }
        }

        // A compressed Packet contains more packets
        let _Nullable compressedPacket = PGPCast(packet, PGPCompressedPacket);
        if (compressedPacket) {
            let packets = [self readPacketsFromData:compressedPacket.decompressedData offset:0 mdcLength:nil];
            if (packets) {
                [accumulatedPackets addObjectsFromArray:packets];
            }
        }

        if (packet.indeterminateLength && accumulatedPackets.count > 0 && PGPCast(accumulatedPackets.firstObject, PGPCompressedPacket)) {
            //FIXME: substract size of PGPModificationDetectionCodePacket in this very special case - TODO: fix this
            offset -= 22;
            if (mdcLength) {
                *mdcLength -= 22;
            }
        }

        // corrupted data. Move by one byte in hope we find some packet there, or EOF.
        if (nextPacketOffset == 0) {
            offset++;
        }
        offset = offset + (NSInteger)nextPacketOffset;
    }
    return accumulatedPackets;
}

// return array of packets
- (NSArray<PGPPacket *> *)decryptWithSecretKeyPacket:(PGPSecretKeyPacket *)secretKeyPacket sessionKeyAlgorithm:(PGPSymmetricAlgorithm)sessionKeyAlgorithm sessionKeyData:(NSData *)sessionKeyData error:(NSError * __autoreleasing _Nullable *)error {
    NSAssert(self.encryptedData, @"Missing encrypted data to decrypt");
    NSAssert(secretKeyPacket, @"Missing secret key");

    if (!self.encryptedData) {
        if (error) {
            *error = [NSError errorWithDomain:PGPErrorDomain code:0 userInfo:@{ NSLocalizedDescriptionKey: @"Missing encrypted data" }];
        }
        return @[];
    }

    if (secretKeyPacket.isEncryptedWithPassphrase) {
        if (error) {
            *error = [NSError errorWithDomain:PGPErrorDomain code:0 userInfo:@{ NSLocalizedDescriptionKey: @"Encrypted secret key used to decryption. Decrypt key first" }];
        }
        return @[];
    }

    NSUInteger blockSize = [PGPCryptoUtils blockSizeOfSymmetricAlhorithm:sessionKeyAlgorithm];

    // The Initial Vector (IV) is specified as all zeros.
    let ivData = [NSMutableData dataWithLength:blockSize];

    NSUInteger position = 0;
    // preamble + data + mdc
    let decryptedData = [PGPCryptoCFB decryptData:self.encryptedData sessionKeyData:sessionKeyData symmetricAlgorithm:sessionKeyAlgorithm iv:ivData];
    // full prefix blockSize + 2
    let prefixRandomFullData = [decryptedData subdataWithRange:(NSRange){position, blockSize + 2}];
    position = position + blockSize + 2;

    // check if suffix match
    if (!PGPEqualObjects([prefixRandomFullData subdataWithRange:(NSRange){blockSize + 2 - 4, 2}] ,[prefixRandomFullData subdataWithRange:(NSRange){blockSize + 2 - 2, 2}])) {
        if (error) {
            *error = [NSError errorWithDomain:PGPErrorDomain code:0 userInfo:@{ NSLocalizedDescriptionKey: @"Random suffix mismatch" }];
        }
        return @[];
    }

    NSUInteger mdcLength = 0;
    let packets = [self readPacketsFromData:decryptedData offset:position mdcLength:&mdcLength];
    return [packets subarrayWithRange:(NSRange){0, packets.count - 1}];
}

#pragma mark - isEqual

- (BOOL)isEqual:(id)other {
    if (self == other) { return YES; }
    if ([super isEqual:other] && [other isKindOfClass:self.class]) {
        return [self isEqualToSymmetricallyEncryptedDataPacket:other];
    }
    return NO;
}

- (BOOL)isEqualToSymmetricallyEncryptedDataPacket:(PGPSymmetricallyEncryptedDataPacket *)packet {
    return PGPEqualObjects(self.encryptedData, packet.encryptedData);
}

- (NSUInteger)hash {
    NSUInteger prime = 31;
    NSUInteger result = [super hash];
    result = prime * result + self.encryptedData.hash;
    return result;
}

#pragma mark - NSCopying

- (id)copyWithZone:(nullable NSZone *)zone {
    let _Nullable duplicate = PGPCast([super copyWithZone:zone], PGPSymmetricallyEncryptedDataPacket);
    if (!duplicate) {
        return nil;
    }
    duplicate.encryptedData = self.encryptedData;
    return duplicate;
}

@end

NS_ASSUME_NONNULL_END
