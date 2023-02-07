const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const frame = types.frame;
const LiteralsSection = types.compressed_block.LiteralsSection;
const SequencesSection = types.compressed_block.SequencesSection;
const Table = types.compressed_block.Table;

pub const block = @import("decode/block.zig");

pub const RingBuffer = @import("RingBuffer.zig");

const readers = @import("readers.zig");

const readInt = std.mem.readIntLittle;
const readIntSlice = std.mem.readIntSliceLittle;
fn readVarInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readVarInt(T, bytes, .Little);
}

pub fn isSkippableMagic(magic: u32) bool {
    return frame.Skippable.magic_number_min <= magic and magic <= frame.Skippable.magic_number_max;
}

/// Returns the kind of frame at the beginning of `src`.
///
/// Errors returned:
///   - `error.BadMagic` if `source` begins with bytes not equal to the
///     Zstandard frame magic number, or outside the range of magic numbers for
///     skippable frames.
///   - `error.EndOfStream` if `source` contains fewer than 4 bytes
pub fn decodeFrameType(source: anytype) error{ BadMagic, EndOfStream }!frame.Kind {
    const magic = try source.readIntLittle(u32);
    return frameType(magic);
}

/// Returns the kind of frame associated to `magic`.
///
/// Errors returned:
///   - `error.BadMagic` if `magic` is not a valid magic number.
pub fn frameType(magic: u32) error{BadMagic}!frame.Kind {
    return if (magic == frame.Zstandard.magic_number)
        .zstandard
    else if (isSkippableMagic(magic))
        .skippable
    else
        error.BadMagic;
}

const ReadWriteCount = struct {
    read_count: usize,
    write_count: usize,
};

/// Decodes frames from `src` into `dest`; see `decodeFrame()`.
pub fn decode(dest: []u8, src: []const u8, verify_checksum: bool) !usize {
    var write_count: usize = 0;
    var read_count: usize = 0;
    while (read_count < src.len) {
        const counts = try decodeFrame(dest, src[read_count..], verify_checksum);
        read_count += counts.read_count;
        write_count += counts.write_count;
    }
    return write_count;
}

pub fn decodeAlloc(
    allocator: Allocator,
    src: []const u8,
    verify_checksum: bool,
    window_size_max: usize,
) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var read_count: usize = 0;
    while (read_count < src.len) {
        read_count += try decodeFrameArrayList(
            allocator,
            &result,
            src[read_count..],
            verify_checksum,
            window_size_max,
        );
    }
    return result.toOwnedSlice();
}

/// Decodes the frame at the start of `src` into `dest`. Returns the number of
/// bytes read from `src` and written to `dest`. This function can only decode
/// frames that declare the decompressed content size.
///
/// Errors returned:
///   - `error.UnknownContentSizeUnsupported` if the frame does not declare the
///     uncompressed content size
///   - `error.ContentTooLarge` if `dest` is smaller than the uncompressed data
///     size declared by the frame header
///   - `error.BadMagic` if the first 4 bytes of `src` is not a valid magic
///     number for a Zstandard or Skippable frame
///   - `error.DictionaryIdFlagUnsupported` if the frame uses a dictionary
///   - `error.ChecksumFailure` if `verify_checksum` is true and the frame
///     contains a checksum that does not match the checksum of the decompressed
///     data
///   - `error.ReservedBitSet` if the reserved bit of the frame header is set
///   - `error.UnusedBitSet` if the unused bit of the frame header is set
///   - `error.EndOfStream` if `src` does not contain a complete frame
///   - an error in `block.Error` if there are errors decoding a block
///   - `error.SkippableSizeTooLarge` if the frame is skippable and reports a
///     size greater than `src.len`
pub fn decodeFrame(
    dest: []u8,
    src: []const u8,
    verify_checksum: bool,
) !ReadWriteCount {
    var fbs = std.io.fixedBufferStream(src);
    switch (try decodeFrameType(fbs.reader())) {
        .zstandard => return decodeZstandardFrame(dest, src, verify_checksum),
        .skippable => {
            const content_size = try fbs.reader().readIntLittle(u32);
            if (content_size > std.math.maxInt(usize) - 8) return error.SkippableSizeTooLarge;
            const read_count = @as(usize, content_size) + 8;
            if (read_count > src.len) return error.SkippableSizeTooLarge;
            return ReadWriteCount{
                .read_count = read_count,
                .write_count = 0,
            };
        },
    }
}

pub const DecodeResult = struct {
    bytes: []u8,
    read_count: usize,
};
pub const DecodedFrame = union(enum) {
    zstandard: DecodeResult,
    skippable: frame.Skippable.Header,
};

/// Decodes the frame at the start of `src` into `dest`. Returns the number of
/// bytes read from `src`.
///
/// Errors returned:
///   - `error.BadMagic` if the first 4 bytes of `src` is not a valid magic
///     number for a Zstandard or Skippable frame
///   - `error.WindowSizeUnknown` if the frame does not have a valid window size
///   - `error.WindowTooLarge` if the window size is larger than
///     `window_size_max`
///   - `error.DictionaryIdFlagUnsupported` if the frame uses a dictionary
///   - `error.ChecksumFailure` if `verify_checksum` is true and the frame
///     contains a checksum that does not match the checksum of the decompressed
///     data
///   - `error.ReservedBitSet` if the reserved bit of the frame header is set
///   - `error.UnusedBitSet` if the unused bit of the frame header is set
///   - `error.EndOfStream` if `src` does not contain a complete frame
///   - `error.OutOfMemory` if `allocator` cannot allocate enough memory
///   - an error in `block.Error` if there are errors decoding a block
///   - `error.SkippableSizeTooLarge` if the frame is skippable and reports a
///     size greater than `src.len`
pub fn decodeFrameArrayList(
    allocator: Allocator,
    dest: *std.ArrayList(u8),
    src: []const u8,
    verify_checksum: bool,
    window_size_max: usize,
) !usize {
    var fbs = std.io.fixedBufferStream(src);
    const reader = fbs.reader();
    const magic = try reader.readIntLittle(u32);
    switch (try frameType(magic)) {
        .zstandard => return decodeZstandardFrameArrayList(allocator, dest, src, verify_checksum, window_size_max),
        .skippable => {
            const content_size = try fbs.reader().readIntLittle(u32);
            if (content_size > std.math.maxInt(usize) - 8) return error.SkippableSizeTooLarge;
            const read_count = @as(usize, content_size) + 8;
            if (read_count > src.len) return error.SkippableSizeTooLarge;
            return read_count;
        },
    }
}

/// Returns the frame checksum corresponding to the data fed into `hasher`
pub fn computeChecksum(hasher: *std.hash.XxHash64) u32 {
    const hash = hasher.final();
    return @intCast(u32, hash & 0xFFFFFFFF);
}

const FrameError = error{
    DictionaryIdFlagUnsupported,
    ChecksumFailure,
    BadContentSize,
    EndOfStream,
} || InvalidBit || block.Error;

/// Decode a Zstandard frame from `src` into `dest`, returning the number of
/// bytes read from `src` and written to `dest`. The first four bytes of `src`
/// must be the magic number for a Zstandard frame.
///
/// Error returned:
///   - `error.UnknownContentSizeUnsupported` if the frame does not declare the
///     uncompressed content size
///   - `error.ContentTooLarge` if `dest` is smaller than the uncompressed data
///     size declared by the frame header
///   - `error.DictionaryIdFlagUnsupported` if the frame uses a dictionary
///   - `error.ChecksumFailure` if `verify_checksum` is true and the frame
///     contains a checksum that does not match the checksum of the decompressed
///     data
///   - `error.ReservedBitSet` if the reserved bit of the frame header is set
///   - `error.UnusedBitSet` if the unused bit of the frame header is set
///   - `error.EndOfStream` if `src` does not contain a complete frame
///   - an error in `block.Error` if there are errors decoding a block
///   - `error.BadContentSize` if the content size declared by the frame does
///     not equal the actual size of decompressed data
pub fn decodeZstandardFrame(
    dest: []u8,
    src: []const u8,
    verify_checksum: bool,
) (error{
    UnknownContentSizeUnsupported,
    ContentTooLarge,
    ContentSizeTooLarge,
    WindowSizeUnknown,
} || FrameError)!ReadWriteCount {
    assert(readInt(u32, src[0..4]) == frame.Zstandard.magic_number);
    var consumed_count: usize = 4;

    var frame_context = context: {
        var fbs = std.io.fixedBufferStream(src[consumed_count..]);
        var source = fbs.reader();
        const frame_header = try decodeZstandardHeader(source);
        consumed_count += fbs.pos;
        break :context FrameContext.init(frame_header, std.math.maxInt(usize), verify_checksum) catch |err| switch (err) {
            error.WindowTooLarge => unreachable,
            inline else => |e| return e,
        };
    };

    const content_size = frame_context.content_size orelse return error.UnknownContentSizeUnsupported;
    if (dest.len < content_size) return error.ContentTooLarge;

    const written_count = decodeFrameBlocks(
        dest[0..content_size],
        src[consumed_count..],
        &consumed_count,
        if (frame_context.hasher_opt) |*hasher| hasher else null,
        frame_context.block_size_max,
    ) catch |err| switch (err) {
        error.DestTooSmall => return error.BadContentSize,
        inline else => |e| return e,
    };

    if (written_count != content_size) return error.BadContentSize;
    if (frame_context.has_checksum) {
        if (src.len < consumed_count + 4) return error.EndOfStream;
        const checksum = readIntSlice(u32, src[consumed_count .. consumed_count + 4]);
        consumed_count += 4;
        if (frame_context.hasher_opt) |*hasher| {
            if (checksum != computeChecksum(hasher)) return error.ChecksumFailure;
        }
    }
    return ReadWriteCount{ .read_count = consumed_count, .write_count = written_count };
}

pub const FrameContext = struct {
    hasher_opt: ?std.hash.XxHash64,
    window_size: usize,
    has_checksum: bool,
    block_size_max: usize,
    content_size: ?usize,

    const Error = error{
        DictionaryIdFlagUnsupported,
        WindowSizeUnknown,
        WindowTooLarge,
        ContentSizeTooLarge,
    };
    /// Validates `frame_header` and returns the associated `FrameContext`.
    ///
    /// Errors returned:
    ///   - `error.DictionaryIdFlagUnsupported` if the frame uses a dictionary
    ///   - `error.WindowSizeUnknown` if the frame does not have a valid window size
    ///   - `error.WindowTooLarge` if the window size is larger than
    pub fn init(
        frame_header: frame.Zstandard.Header,
        window_size_max: usize,
        verify_checksum: bool,
    ) Error!FrameContext {
        if (frame_header.descriptor.dictionary_id_flag != 0) return error.DictionaryIdFlagUnsupported;

        const window_size_raw = frameWindowSize(frame_header) orelse return error.WindowSizeUnknown;
        const window_size = if (window_size_raw > window_size_max)
            return error.WindowTooLarge
        else
            @intCast(usize, window_size_raw);

        const should_compute_checksum = frame_header.descriptor.content_checksum_flag and verify_checksum;

        const content_size = if (frame_header.content_size) |size|
            std.math.cast(usize, size) orelse return error.ContentSizeTooLarge
        else
            null;

        return .{
            .hasher_opt = if (should_compute_checksum) std.hash.XxHash64.init(0) else null,
            .window_size = window_size,
            .has_checksum = frame_header.descriptor.content_checksum_flag,
            .block_size_max = @min(1 << 17, window_size),
            .content_size = content_size,
        };
    }
};

/// Decode a Zstandard from from `src` and return number of bytes read; see
/// `decodeZstandardFrame()`. The first four bytes of `src` must be the magic
/// number for a Zstandard frame.
///
/// Errors returned:
///   - `error.WindowSizeUnknown` if the frame does not have a valid window size
///   - `error.WindowTooLarge` if the window size is larger than
///     `window_size_max`
///   - `error.DictionaryIdFlagUnsupported` if the frame uses a dictionary
///   - `error.ChecksumFailure` if `verify_checksum` is true and the frame
///     contains a checksum that does not match the checksum of the decompressed
///     data
///   - `error.ReservedBitSet` if the reserved bit of the frame header is set
///   - `error.UnusedBitSet` if the unused bit of the frame header is set
///   - `error.EndOfStream` if `src` does not contain a complete frame
///   - `error.OutOfMemory` if `allocator` cannot allocate enough memory
///   - an error in `block.Error` if there are errors decoding a block
///   - `error.BadContentSize` if the content size declared by the frame does
///     not equal the size of decompressed data
pub fn decodeZstandardFrameArrayList(
    allocator: Allocator,
    dest: *std.ArrayList(u8),
    src: []const u8,
    verify_checksum: bool,
    window_size_max: usize,
) (error{OutOfMemory} || FrameContext.Error || FrameError)!usize {
    assert(readInt(u32, src[0..4]) == frame.Zstandard.magic_number);
    const initial_len = dest.items.len;
    var consumed_count: usize = 4;

    var frame_context = context: {
        var fbs = std.io.fixedBufferStream(src[consumed_count..]);
        var source = fbs.reader();
        const frame_header = try decodeZstandardHeader(source);
        consumed_count += fbs.pos;
        break :context try FrameContext.init(frame_header, window_size_max, verify_checksum);
    };

    var ring_buffer = try RingBuffer.init(allocator, frame_context.window_size);
    defer ring_buffer.deinit(allocator);

    // These tables take 7680 bytes
    var literal_fse_data: [types.compressed_block.table_size_max.literal]Table.Fse = undefined;
    var match_fse_data: [types.compressed_block.table_size_max.match]Table.Fse = undefined;
    var offset_fse_data: [types.compressed_block.table_size_max.offset]Table.Fse = undefined;

    var block_header = try block.decodeBlockHeaderSlice(src[consumed_count..]);
    consumed_count += 3;
    var decode_state = block.DecodeState.init(&literal_fse_data, &match_fse_data, &offset_fse_data);
    while (true) : ({
        block_header = try block.decodeBlockHeaderSlice(src[consumed_count..]);
        consumed_count += 3;
    }) {
        const written_size = try block.decodeBlockRingBuffer(
            &ring_buffer,
            src[consumed_count..],
            block_header,
            &decode_state,
            &consumed_count,
            frame_context.block_size_max,
        );
        if (written_size > 0) {
            const written_slice = ring_buffer.sliceLast(written_size);
            try dest.appendSlice(written_slice.first);
            try dest.appendSlice(written_slice.second);
            if (frame_context.hasher_opt) |*hasher| {
                hasher.update(written_slice.first);
                hasher.update(written_slice.second);
            }
        }
        const added_len = dest.items.len - initial_len;
        if (frame_context.content_size) |size| {
            if (added_len != size) {
                return error.BadContentSize;
            }
        }
        if (block_header.last_block) break;
    }

    if (frame_context.has_checksum) {
        if (src.len < consumed_count + 4) return error.EndOfStream;
        const checksum = readIntSlice(u32, src[consumed_count .. consumed_count + 4]);
        consumed_count += 4;
        if (frame_context.hasher_opt) |*hasher| {
            if (checksum != computeChecksum(hasher)) return error.ChecksumFailure;
        }
    }
    return consumed_count;
}

/// Convenience wrapper for decoding all blocks in a frame; see `decodeBlock()`.
fn decodeFrameBlocks(
    dest: []u8,
    src: []const u8,
    consumed_count: *usize,
    hash: ?*std.hash.XxHash64,
    block_size_max: usize,
) (error{ EndOfStream, DestTooSmall } || block.Error)!usize {
    // These tables take 7680 bytes
    var literal_fse_data: [types.compressed_block.table_size_max.literal]Table.Fse = undefined;
    var match_fse_data: [types.compressed_block.table_size_max.match]Table.Fse = undefined;
    var offset_fse_data: [types.compressed_block.table_size_max.offset]Table.Fse = undefined;

    var block_header = try block.decodeBlockHeaderSlice(src);
    var bytes_read: usize = 3;
    defer consumed_count.* += bytes_read;
    var decode_state = block.DecodeState.init(&literal_fse_data, &match_fse_data, &offset_fse_data);
    var written_count: usize = 0;
    while (true) : ({
        block_header = try block.decodeBlockHeaderSlice(src[bytes_read..]);
        bytes_read += 3;
    }) {
        const written_size = try block.decodeBlock(
            dest,
            src[bytes_read..],
            block_header,
            &decode_state,
            &bytes_read,
            block_size_max,
            written_count,
        );
        if (hash) |hash_state| hash_state.update(dest[written_count .. written_count + written_size]);
        written_count += written_size;
        if (block_header.last_block) break;
    }
    return written_count;
}

/// Decode the header of a skippable frame. The first four bytes of `src` must
/// be a valid magic number for a Skippable frame.
pub fn decodeSkippableHeader(src: *const [8]u8) frame.Skippable.Header {
    const magic = readInt(u32, src[0..4]);
    assert(isSkippableMagic(magic));
    const frame_size = readInt(u32, src[4..8]);
    return .{
        .magic_number = magic,
        .frame_size = frame_size,
    };
}

/// Returns the window size required to decompress a frame, or `null` if it
/// cannot be determined (which indicates a malformed frame header).
pub fn frameWindowSize(header: frame.Zstandard.Header) ?u64 {
    if (header.window_descriptor) |descriptor| {
        const exponent = (descriptor & 0b11111000) >> 3;
        const mantissa = descriptor & 0b00000111;
        const window_log = 10 + exponent;
        const window_base = @as(u64, 1) << @intCast(u6, window_log);
        const window_add = (window_base / 8) * mantissa;
        return window_base + window_add;
    } else return header.content_size;
}

const InvalidBit = error{ UnusedBitSet, ReservedBitSet };
/// Decode the header of a Zstandard frame.
///
/// Errors returned:
///   - `error.UnusedBitSet` if the unused bits of the header are set
///   - `error.ReservedBitSet` if the reserved bits of the header are set
///   - `error.EndOfStream` if `source` does not contain a complete header
pub fn decodeZstandardHeader(source: anytype) (error{EndOfStream} || InvalidBit)!frame.Zstandard.Header {
    const descriptor = @bitCast(frame.Zstandard.Header.Descriptor, try source.readByte());

    if (descriptor.unused) return error.UnusedBitSet;
    if (descriptor.reserved) return error.ReservedBitSet;

    var window_descriptor: ?u8 = null;
    if (!descriptor.single_segment_flag) {
        window_descriptor = try source.readByte();
    }

    var dictionary_id: ?u32 = null;
    if (descriptor.dictionary_id_flag > 0) {
        // if flag is 3 then field_size = 4, else field_size = flag
        const field_size = (@as(u4, 1) << descriptor.dictionary_id_flag) >> 1;
        dictionary_id = try source.readVarInt(u32, .Little, field_size);
    }

    var content_size: ?u64 = null;
    if (descriptor.single_segment_flag or descriptor.content_size_flag > 0) {
        const field_size = @as(u4, 1) << descriptor.content_size_flag;
        content_size = try source.readVarInt(u64, .Little, field_size);
        if (field_size == 2) content_size.? += 256;
    }

    const header = frame.Zstandard.Header{
        .descriptor = descriptor,
        .window_descriptor = window_descriptor,
        .dictionary_id = dictionary_id,
        .content_size = content_size,
    };
    return header;
}

test {
    std.testing.refAllDecls(@This());
}
