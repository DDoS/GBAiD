module gbaid.gba.save;

import std.format : format;
import std.typecons : tuple, Tuple;
import std.stdio : File;
import std.bitmanip : littleEndianToNative, nativeToLittleEndian;
import std.digest.crc : CRC32;
import std.zlib : compress, uncompress;

import gbaid.util;

public alias RawSaveMemory = Tuple!(SaveMemoryKind, ubyte[]);

public enum SaveMemoryKind : int {
    EEPROM = 0,
    SRAM = 1,
    FLASH_512K = 2,
    FLASH_1M = 3,
    RTC = 4,
    UNKNOWN = -1
}

private enum int SAVE_CURRENT_VERSION = 1;
private immutable char[8] SAVE_FORMAT_MAGIC = "GBAiDSav";

public enum int[SaveMemoryKind] memoryCapacityForSaveKind = [
    SaveMemoryKind.EEPROM: 8 * BYTES_PER_KIB,
    SaveMemoryKind.SRAM: 32 * BYTES_PER_KIB,
    SaveMemoryKind.FLASH_512K: 64 * BYTES_PER_KIB,
    SaveMemoryKind.FLASH_1M: 128 * BYTES_PER_KIB,
    SaveMemoryKind.RTC: 24,
];

/*
All ints are 32 bit and stored in little endian.
The CRCs are calculated on the little endian values

Format:
    Header:
        8 bytes: magic number (ASCII string of "GBAiDSav")
        1 int: version number
        1 int: option flags
        1 int: number of memory objects (n)
        1 int: CRC of the memory header (excludes magic number)
    Body:
        n memory blocks:
            1 int: memory kind ID, as per the SaveMemoryKind enum
            1 int: compressed memory size in bytes (c)
            c bytes: memory compressed with zlib
            1 int: CRC of the memory block
*/

public RawSaveMemory[] loadSaveFile(string filePath) {
    // Open the file in binary to read
    auto file = File(filePath, "rb");
    // Read the first 8 bytes to make sure it is a save file for GBAiD
    char[8] magicChars;
    file.rawRead(magicChars);
    if (magicChars != SAVE_FORMAT_MAGIC) {
        throw new Exception(format("Not a GBAiD save file (magic number isn't \"%s\" in ASCII)", SAVE_FORMAT_MAGIC));
    }
    // Read the version number
    auto versionNumber = file.readLittleEndianInt();
    // Use the proper reader for the version
    switch (versionNumber) {
        case 1:
            return file.readRawSaveMemories!1();
        default:
            throw new Exception(format("Unknown save file version: %d", versionNumber));
    }
}

private RawSaveMemory[] readRawSaveMemories(int versionNumber: 1)(File file) {
    CRC32 hash;
    hash.put([0x1, 0x0, 0x0, 0x0]);
    // Read the options flags, which are unused in this version
    auto optionFlags = file.readLittleEndianInt(&hash);
    // Read the number of save memories in the file
    auto memoryCount = file.readLittleEndianInt(&hash);
    // Read the header CRC checksum
    ubyte[4] headerCrc;
    file.rawRead(headerCrc);
    // Check the CRC
    if (hash.finish() != headerCrc) {
        throw new Exception("The save file has a corrupted header, the CRCs do not match");
    }
    // Read all the raw save memories according to the configurations given by the header
    RawSaveMemory[] saveMemories;
    foreach (i; 0 .. memoryCount) {
        saveMemories ~= file.readRawSaveMemory!versionNumber();
    }
    return saveMemories;
}

private RawSaveMemory readRawSaveMemory(int versionNumber: 1)(File file) {
    CRC32 hash;
    // Read the memory kind
    auto kindId = file.readLittleEndianInt(&hash);
    // Read the memory compressed size
    auto compressedSize = file.readLittleEndianInt(&hash);
    // Read the compressed bytes for the memory
    ubyte[] memoryCompressed;
    memoryCompressed.length = compressedSize;
    file.rawRead(memoryCompressed);
    hash.put(memoryCompressed);
    // Read the block CRC checksum
    ubyte[4] blockCrc;
    file.rawRead(blockCrc);
    // Check the CRC
    if (hash.finish() != blockCrc) {
        throw new Exception("The save file has a corrupted memory block, the CRCs do not match");
    }
    // Get the memory length according to the kind
    auto saveKind = cast(SaveMemoryKind) kindId;
    auto uncompressedSize = memoryCapacityForSaveKind[saveKind];
    // Uncompress the memory
    auto memoryUncompressed = cast(ubyte[]) memoryCompressed.uncompress(uncompressedSize);
    // Check that the uncompressed length matches the one for the kind
    if (memoryUncompressed.length != uncompressedSize) {
        throw new Exception(format("The uncompressed save memory has a different length than its kind: %d != %d",
                memoryUncompressed.length, uncompressedSize));
    }
    return tuple(saveKind, memoryUncompressed);
}

public void saveSaveFile(RawSaveMemory[] saveMemories, string filePath) {
    // Open the file in binary to write
    auto file = File(filePath, "wb");
    // First we write the magic
    file.rawWrite(SAVE_FORMAT_MAGIC);
    // Next we write the current version
    CRC32 hash;
    file.writeLittleEndianInt(SAVE_CURRENT_VERSION, &hash);
    // Next we write the option flags, which are empty since they are unused
    file.writeLittleEndianInt(0, &hash);
    // Next we write the number of memory blocks
    file.writeLittleEndianInt(cast(int) saveMemories.length, &hash);
    // Next we write the header CRC
    file.rawWrite(hash.finish());
    // Finally write the memory blocks
    foreach (saveMemory; saveMemories) {
        file.writeRawSaveMemory(saveMemory);
    }
}

private void writeRawSaveMemory(File file, RawSaveMemory saveMemory) {
    CRC32 hash;
    // Write the memory kind
    file.writeLittleEndianInt(saveMemory[0], &hash);
    // Compress the save memory
    auto memoryCompressed = saveMemory[1].compress();
    // Write the memory compressed size
    file.writeLittleEndianInt(cast(int) memoryCompressed.length, &hash);
    // Write the compressed bytes for the memory
    hash.put(memoryCompressed);
    file.rawWrite(memoryCompressed);
    // Write the block CRC
    file.rawWrite(hash.finish());
}

private int readLittleEndianInt(File file, CRC32* hash = null) {
    ubyte[4] numberBytes;
    file.rawRead(numberBytes);
    if (hash !is null) {
        hash.put(numberBytes);
    }
    return numberBytes.littleEndianToNative!int();
}

private void writeLittleEndianInt(File file, int i, CRC32* hash = null) {
    auto numberBytes = i.nativeToLittleEndian();
    if (hash !is null) {
        hash.put(numberBytes);
    }
    file.rawWrite(numberBytes);
}
