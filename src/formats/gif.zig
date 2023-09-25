const FormatInterface = @import("../format_interface.zig").FormatInterface;
const PixelFormat = @import("../pixel_format.zig").PixelFormat;
const color = @import("../color.zig");
const Image = @import("../Image.zig");
const std = @import("std");
const utils = @import("../utils.zig");
const lzw = @import("../compressions/lzw.zig");

const ImageReadError = Image.ReadError;
const ImageWriteError = Image.WriteError;

pub const HeaderFlags = packed struct {
    global_color_table_size: u3 = 0,
    sorted: bool = false,
    color_resolution: u3 = 0,
    use_global_color_table: bool = false,
};

pub const Header = extern struct {
    magic: [3]u8 align(1) = undefined,
    version: [3]u8 align(1) = undefined,
    width: u16 align(1) = 0,
    height: u16 align(1) = 0,
    flags: HeaderFlags align(1) = .{},
    background_color_index: u8 align(1) = 0,
    pixel_aspect_ratio: u8 align(1) = 0,
};

pub const ImageDescriptorFlags = packed struct(u8) {
    local_color_table_size: u3 = 0,
    reserved: u2 = 0,
    sort: bool = false,
    is_interlaced: bool = false,
    has_local_color_table: bool = false,
};

pub const ImageDescriptor = extern struct {
    left_position: u16 align(1) = 0,
    top_position: u16 align(1) = 0,
    width: u16 align(1) = 0,
    height: u16 align(1) = 0,
    flags: ImageDescriptorFlags align(1) = .{},
};

pub const GraphicControlExtensionFlags = packed struct(u8) {
    has_transparent_color: bool = false,
    user_input: bool = false,
    disposal_method: enum(u3) {
        none = 0,
        do_not_dispose = 1,
        restore_background_color = 2,
        restore_to_previous = 3,
        _,
    } = .none,
    reserved: u3 = 0,
};

pub const GraphicControlExtension = extern struct {
    flags: GraphicControlExtensionFlags align(1) = .{},
    delay_time: u16 align(1) = 0,
    transparent_color_index: u8 align(1) = 0,
};

pub const CommentExtension = struct {
    comment: FixedStorage(u8, 256) = FixedStorage(u8, 256).init(),
};

pub const ApplicationExtension = struct {
    application_identifier: [8]u8,
    authentification_code: [3]u8,
    data: []u8,

    pub fn deinit(self: ApplicationExtension, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

const DataBlockKind = enum((u8)) {
    image_descriptor = 0x2c,
    extension = 0x21,
    end_of_file = 0x3b,
};

const ExtensionKind = enum(u8) {
    graphic_control = 0xf9,
    comment = 0xfe,
    plain_text = 0x01,
    application_extension = 0xff,
};

const Magic = "GIF";

const Versions = [_][]const u8{
    "87a",
    "89a",
};

const ExtensionBlockTerminator = 0x00;

const InterlacePasses = [_]struct { start: usize, step: usize }{
    .{ .start = 0, .step = 8 },
    .{ .start = 4, .step = 8 },
    .{ .start = 2, .step = 4 },
    .{ .start = 1, .step = 2 },
};

// TODO: Move to utils.zig
pub fn FixedStorage(comptime T: type, comptime storage_size: usize) type {
    return struct {
        data: []T,
        storage: [storage_size]T,

        const Self = @This();

        pub fn init() Self {
            var result: Self = undefined;
            return result;
        }

        pub fn resize(self: *Self, size: usize) void {
            self.data = self.storage[0..size];
        }
    };
}

pub const GIF = struct {
    header: Header = .{},
    global_color_table: FixedStorage(color.Rgb24, 256) = FixedStorage(color.Rgb24, 256).init(),
    frames: std.ArrayListUnmanaged(FrameData) = .{},
    comments: std.ArrayListUnmanaged(CommentExtension) = .{},
    application_infos: std.ArrayListUnmanaged(ApplicationExtension) = .{},
    allocator: std.mem.Allocator = undefined,

    pub const SubImage = struct {
        local_color_table: FixedStorage(color.Rgb24, 256) = FixedStorage(color.Rgb24, 256).init(),
        image_descriptor: ImageDescriptor = .{},
        pixels: []u8 = &.{},

        pub fn deinit(self: SubImage, allocator: std.mem.Allocator) void {
            allocator.free(self.pixels);
        }
    };

    pub const FrameData = struct {
        graphics_control: ?GraphicControlExtension = null,
        sub_images: std.ArrayListUnmanaged(SubImage) = .{},

        pub fn deinit(self: *FrameData, allocator: std.mem.Allocator) void {
            for (self.sub_images.items) |sub_image| {
                sub_image.deinit(allocator);
            }

            self.sub_images.deinit(allocator);
        }

        pub fn allocNewSubImage(self: *FrameData, allocator: std.mem.Allocator) !*SubImage {
            var new_sub_image = try self.sub_images.addOne(allocator);
            new_sub_image.* = SubImage{};
            return new_sub_image;
        }
    };

    const ReaderContext = struct {
        reader: Image.Stream.Reader = undefined,
        current_frame_data: ?*FrameData = null,
    };

    pub fn init(allocator: std.mem.Allocator) GIF {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GIF) void {
        for (self.frames.items) |*frame| {
            frame.deinit(self.allocator);
        }

        for (self.application_infos.items) |application_info| {
            application_info.deinit(self.allocator);
        }

        self.frames.deinit(self.allocator);
        self.comments.deinit(self.allocator);
        self.application_infos.deinit(self.allocator);
    }

    pub fn formatInterface() FormatInterface {
        return FormatInterface{
            .format = format,
            .formatDetect = formatDetect,
            .readImage = readImage,
            .writeImage = writeImage,
        };
    }

    pub fn format() Image.Format {
        return Image.Format.gif;
    }

    pub fn formatDetect(stream: *Image.Stream) !bool {
        var header_buffer: [6]u8 = undefined;
        const read_bytes = try stream.read(header_buffer[0..]);
        if (read_bytes < 6) {
            return false;
        }

        for (Versions) |version| {
            if (std.mem.eql(u8, header_buffer[0..Magic.len], Magic) and std.mem.eql(u8, header_buffer[Magic.len..], version)) {
                return true;
            }
        }

        return false;
    }

    pub fn readImage(allocator: std.mem.Allocator, stream: *Image.Stream) ImageReadError!Image {
        var result = Image.init(allocator);
        errdefer result.deinit();

        var gif = GIF.init(allocator);
        defer gif.deinit();

        var frames = try gif.read(stream);
        if (frames.items.len == 0) {
            return ImageReadError.InvalidData;
        }

        result.width = gif.header.width;
        result.height = gif.header.height;
        result.pixels = frames.items[0].pixels;
        result.animation.frames = frames;
        result.animation.loop_count = gif.loopCount();
        return result;
    }

    pub fn writeImage(allocator: std.mem.Allocator, write_stream: *Image.Stream, image: Image, encoder_options: Image.EncoderOptions) Image.Stream.WriteError!void {
        _ = allocator;
        _ = write_stream;
        _ = image;
        _ = encoder_options;
    }

    pub fn loopCount(self: GIF) i32 {
        _ = self;
        // TODO: mlarouche: Read this information from the application extension
        return Image.AnimationLoopInfinite;
    }

    pub fn read(self: *GIF, stream: *Image.Stream) ImageReadError!Image.Animation.FrameList {
        var context = ReaderContext{
            .reader = stream.reader(),
        };

        self.header = try utils.readStructLittle(context.reader, Header);

        if (!std.mem.eql(u8, self.header.magic[0..], Magic)) {
            return ImageReadError.InvalidData;
        }

        var valid_version = false;

        for (Versions) |version| {
            if (std.mem.eql(u8, self.header.version[0..], version)) {
                valid_version = true;
                break;
            }
        }

        if (!valid_version) {
            return ImageReadError.InvalidData;
        }

        const global_color_table_size = @as(usize, 1) << (@as(u6, @intCast(self.header.flags.global_color_table_size)) + 1);

        self.global_color_table.resize(global_color_table_size);

        if (self.header.flags.use_global_color_table) {
            var index: usize = 0;

            while (index < global_color_table_size) : (index += 1) {
                self.global_color_table.data[index] = try utils.readStructLittle(context.reader, color.Rgb24);
            }
        }

        try self.readData(&context);

        return try self.render();
    }

    // <Data> ::= <Graphic Block> | <Special-Purpose Block>
    fn readData(self: *GIF, context: *ReaderContext) ImageReadError!void {
        var current_block = context.reader.readEnum(DataBlockKind, .Little) catch {
            return ImageReadError.InvalidData;
        };

        while (current_block != .end_of_file) {
            var is_graphic_block = false;
            var extension_kind: ?ExtensionKind = null;

            switch (current_block) {
                .image_descriptor => {
                    is_graphic_block = true;
                },
                .extension => {
                    extension_kind = context.reader.readEnum(ExtensionKind, .Little) catch {
                        return ImageReadError.InvalidData;
                    };

                    switch (extension_kind.?) {
                        .graphic_control => {
                            is_graphic_block = true;
                        },
                        .plain_text => {
                            is_graphic_block = true;
                        },
                        else => {},
                    }
                },
                .end_of_file => {
                    return;
                },
            }

            if (is_graphic_block) {
                try self.readGraphicBlock(context, current_block, extension_kind);
            } else {
                try self.readSpecialPurposeBlock(context, extension_kind.?);
            }

            current_block = context.reader.readEnum(DataBlockKind, .Little) catch {
                return ImageReadError.InvalidData;
            };
        }
    }

    // <Graphic Block> ::= [Graphic Control Extension] <Graphic-Rendering Block>
    fn readGraphicBlock(self: *GIF, context: *ReaderContext, block_kind: DataBlockKind, extension_kind_opt: ?ExtensionKind) ImageReadError!void {
        if (extension_kind_opt) |extension_kind| {
            if (extension_kind == .graphic_control) {
                // If we are seeing a Graphics Control Extension block, it means we need to start a new animation frame
                context.current_frame_data = try self.allocNewFrame();

                context.current_frame_data.?.graphics_control = blk: {
                    var graphics_control: GraphicControlExtension = undefined;

                    // Eat block size
                    _ = try context.reader.readByte();

                    graphics_control.flags = try utils.readStructLittle(context.reader, GraphicControlExtensionFlags);
                    graphics_control.delay_time = try context.reader.readIntLittle(u16);

                    if (graphics_control.flags.has_transparent_color) {
                        graphics_control.transparent_color_index = try context.reader.readByte();
                    } else {
                        graphics_control.transparent_color_index = 0;
                    }

                    // Eat block terminator
                    _ = try context.reader.readByte();

                    break :blk graphics_control;
                };

                var new_block_kind = context.reader.readEnum(DataBlockKind, .Little) catch {
                    return ImageReadError.InvalidData;
                };

                // Continue reading the graphics rendering block
                try self.readGraphicRenderingBlock(context, new_block_kind, null);
            } else if (extension_kind == .plain_text) {
                try self.readGraphicRenderingBlock(context, block_kind, extension_kind_opt);
            }
        } else {
            if (context.current_frame_data == null) {
                context.current_frame_data = try self.allocNewFrame();
            }

            try self.readGraphicRenderingBlock(context, block_kind, extension_kind_opt);
        }
    }

    // <Graphic-Rendering Block> ::= <Table-Based Image> | Plain Text Extension
    fn readGraphicRenderingBlock(self: *GIF, context: *ReaderContext, block_kind: DataBlockKind, extension_kind_opt: ?ExtensionKind) ImageReadError!void {
        switch (block_kind) {
            .image_descriptor => {
                try self.readImageDescriptorAndData(context);
            },
            .extension => {
                var extension_kind: ExtensionKind = undefined;
                if (extension_kind_opt) |value| {
                    extension_kind = value;
                } else {
                    extension_kind = context.reader.readEnum(ExtensionKind, .Little) catch {
                        return ImageReadError.InvalidData;
                    };
                }

                switch (extension_kind) {
                    .plain_text => {
                        // Skip plain text extension, it is not worth it to support it
                        const block_size = try context.reader.readByte();
                        try context.reader.skipBytes(block_size, .{});

                        const sub_data_size = try context.reader.readByte();
                        try context.reader.skipBytes(sub_data_size + 1, .{});
                    },
                    else => {
                        return ImageReadError.InvalidData;
                    },
                }
            },
            .end_of_file => {
                return;
            },
        }
    }

    // <Special-Purpose Block> ::= Application Extension | Comment Extension
    fn readSpecialPurposeBlock(self: *GIF, context: *ReaderContext, extension_kind: ExtensionKind) ImageReadError!void {
        switch (extension_kind) {
            .comment => {
                var new_comment_entry = try self.comments.addOne(self.allocator);

                var fixed_alloc = std.heap.FixedBufferAllocator.init(new_comment_entry.comment.storage[0..]);
                var comment_list = std.ArrayList(u8).init(fixed_alloc.allocator());

                var read_data = try context.reader.readByte();

                while (read_data != ExtensionBlockTerminator) {
                    try comment_list.append(read_data);

                    read_data = try context.reader.readByte();
                }

                new_comment_entry.comment.data = comment_list.items;
            },
            .application_extension => {
                const new_application_info = blk: {
                    var application_info: ApplicationExtension = undefined;

                    // Eat block size
                    _ = try context.reader.readByte();

                    _ = try context.reader.read(application_info.application_identifier[0..]);
                    _ = try context.reader.read(application_info.authentification_code[0..]);

                    var data_list = try std.ArrayListUnmanaged(u8).initCapacity(self.allocator, 256);
                    defer data_list.deinit(self.allocator);

                    var read_data = try context.reader.readByte();

                    while (read_data != ExtensionBlockTerminator) {
                        try data_list.append(self.allocator, read_data);

                        read_data = try context.reader.readByte();
                    }

                    application_info.data = try self.allocator.dupe(u8, data_list.items);

                    break :blk application_info;
                };

                try self.application_infos.append(self.allocator, new_application_info);
            },
            else => {
                return ImageReadError.InvalidData;
            },
        }
    }

    // <Table-Based Image> ::= Image Descriptor [Local Color Table] Image Data
    fn readImageDescriptorAndData(self: *GIF, context: *ReaderContext) ImageReadError!void {
        if (context.current_frame_data) |current_frame_data| {
            var sub_image = try current_frame_data.allocNewSubImage(self.allocator);
            sub_image.image_descriptor = try utils.readStructLittle(context.reader, ImageDescriptor);

            // Don't read any futher if the local width or height is zero
            if (sub_image.image_descriptor.width == 0 or sub_image.image_descriptor.height == 0) {
                return;
            }

            const local_color_table_size = @as(usize, 1) << (@as(u6, @intCast(sub_image.image_descriptor.flags.local_color_table_size)) + 1);

            sub_image.local_color_table.resize(local_color_table_size);

            if (sub_image.image_descriptor.flags.has_local_color_table) {
                var index: usize = 0;

                while (index < local_color_table_size) : (index += 1) {
                    sub_image.local_color_table.data[index] = try utils.readStructLittle(context.reader, color.Rgb24);
                }
            }

            sub_image.pixels = try self.allocator.alloc(u8, sub_image.image_descriptor.height * sub_image.image_descriptor.width);
            var pixels_buffer = std.io.fixedBufferStream(sub_image.pixels);

            const lzw_minimum_code_size = try context.reader.readByte();

            if (lzw_minimum_code_size == @intFromEnum(DataBlockKind.end_of_file)) {
                return Image.ReadError.InvalidData;
            }

            var lzw_decoder = try lzw.Decoder(.Little).init(self.allocator, lzw_minimum_code_size);
            defer lzw_decoder.deinit();

            var data_block_size = try context.reader.readByte();

            while (data_block_size > 0) {
                var data_block = FixedStorage(u8, 256).init();
                data_block.resize(data_block_size);

                _ = try context.reader.read(data_block.data[0..]);

                var data_block_reader = Image.Stream{
                    .buffer = std.io.fixedBufferStream(data_block.data),
                };

                lzw_decoder.decode(data_block_reader.reader(), pixels_buffer.writer()) catch |err| {
                    if (err != error.NoSpaceLeft) {
                        return ImageReadError.InvalidData;
                    }
                };

                data_block_size = try context.reader.readByte();
            }
        }
    }

    fn render(self: *GIF) ImageReadError!Image.Animation.FrameList {
        const final_pixel_format = self.findBestPixelFormat();

        var frame_list = Image.Animation.FrameList{};

        if (self.frames.items.len == 0) {
            var current_animation_frame = try self.createNewAnimationFrame(final_pixel_format);
            fillPalette(&current_animation_frame, self.global_color_table.data, null);
            fillWithBackgroundColor(&current_animation_frame, self.global_color_table.data, self.header.background_color_index);
            try frame_list.append(self.allocator, current_animation_frame);
            return frame_list;
        }

        for (self.frames.items) |frame| {
            var current_animation_frame = try self.createNewAnimationFrame(final_pixel_format);

            var transparency_index_opt: ?u8 = null;
            if (frame.graphics_control) |graphics_control| {
                current_animation_frame.duration = @as(f32, @floatFromInt(graphics_control.delay_time)) * (1.0 / 100.0);
                if (graphics_control.flags.has_transparent_color) {
                    transparency_index_opt = graphics_control.transparent_color_index;
                }
            }

            if (self.header.flags.use_global_color_table) {
                fillPalette(&current_animation_frame, self.global_color_table.data, transparency_index_opt);

                if (transparency_index_opt == null) {
                    fillWithBackgroundColor(&current_animation_frame, self.global_color_table.data, self.header.background_color_index);
                }
            }

            for (frame.sub_images.items) |sub_image| {
                const effective_color_table = if (sub_image.image_descriptor.flags.has_local_color_table) sub_image.local_color_table.data else self.global_color_table.data;

                if (sub_image.image_descriptor.flags.has_local_color_table) {
                    fillPalette(&current_animation_frame, effective_color_table, transparency_index_opt);
                }

                self.renderSubImage(&sub_image, &current_animation_frame, effective_color_table, transparency_index_opt);
            }

            try frame_list.append(self.allocator, current_animation_frame);
        }

        return frame_list;
    }

    fn fillPalette(current_frame: *Image.AnimationFrame, effective_color_table: []const color.Rgb24, transparency_index_opt: ?u8) void {
        // TODO: Support transparency index for indexed images
        _ = transparency_index_opt;

        switch (current_frame.pixels) {
            .indexed1 => |pixels| {
                for (0..@min(effective_color_table.len, pixels.palette.len)) |index| {
                    pixels.palette[index] = color.Rgba32.fromU32Rgb(effective_color_table[index].toU32Rgb());
                }
            },
            .indexed2 => |pixels| {
                for (0..@min(effective_color_table.len, pixels.palette.len)) |index| {
                    pixels.palette[index] = color.Rgba32.fromU32Rgb(effective_color_table[index].toU32Rgb());
                }
            },
            .indexed4 => |pixels| {
                for (0..@min(effective_color_table.len, pixels.palette.len)) |index| {
                    pixels.palette[index] = color.Rgba32.fromU32Rgb(effective_color_table[index].toU32Rgb());
                }
            },
            .indexed8 => |pixels| {
                for (0..@min(effective_color_table.len, pixels.palette.len)) |index| {
                    pixels.palette[index] = color.Rgba32.fromU32Rgb(effective_color_table[index].toU32Rgb());
                }
            },
            else => {},
        }
    }

    fn fillWithBackgroundColor(current_frame: *Image.AnimationFrame, effective_color_table: []const color.Rgb24, background_color_index: u8) void {
        if (background_color_index >= effective_color_table.len) {
            return;
        }

        switch (current_frame.pixels) {
            .indexed1 => |pixels| @memset(pixels.indices, @intCast(background_color_index)),
            .indexed2 => |pixels| @memset(pixels.indices, @intCast(background_color_index)),
            .indexed4 => |pixels| @memset(pixels.indices, @intCast(background_color_index)),
            .indexed8 => |pixels| @memset(pixels.indices, background_color_index),
            .rgb24 => |pixels| @memset(pixels, effective_color_table[background_color_index]),
            .rgba32 => |pixels| @memset(pixels, color.Rgba32.fromU32Rgba(effective_color_table[background_color_index].toU32Rgb())),
            else => std.debug.panic("Pixel format {s} not supported", .{@tagName(current_frame.pixels)}),
        }
    }

    fn renderSubImage(self: *const GIF, sub_image: *const SubImage, current_frame: *Image.AnimationFrame, effective_color_table: []const color.Rgb24, transparency_index_opt: ?u8) void {
        if (sub_image.image_descriptor.flags.is_interlaced) {
            var source_y: usize = 0;

            for (InterlacePasses) |pass| {
                var target_y = pass.start + sub_image.image_descriptor.top_position;

                while (target_y < self.header.height) {
                    const source_stride = source_y * sub_image.image_descriptor.width;
                    const target_stride = target_y * self.header.width;

                    for (0..sub_image.image_descriptor.width) |source_x| {
                        const target_x = source_x + sub_image.image_descriptor.left_position;

                        const source_index = source_stride + source_x;
                        const target_index = target_stride + target_x;

                        plotPixel(sub_image, current_frame, effective_color_table, transparency_index_opt, source_index, target_index);
                    }

                    target_y += pass.step;
                    source_y += 1;
                }
            }
        } else {
            for (0..sub_image.image_descriptor.height) |source_y| {
                const target_y = source_y + sub_image.image_descriptor.top_position;

                const source_stride = source_y * sub_image.image_descriptor.width;
                const target_stride = target_y * self.header.width;

                for (0..sub_image.image_descriptor.width) |source_x| {
                    const target_x = source_x + sub_image.image_descriptor.left_position;

                    const source_index = source_stride + source_x;
                    const target_index = target_stride + target_x;

                    plotPixel(sub_image, current_frame, effective_color_table, transparency_index_opt, source_index, target_index);
                }
            }
        }
    }

    fn plotPixel(sub_image: *const SubImage, current_frame: *Image.AnimationFrame, effective_color_table: []const color.Rgb24, transparency_index_opt: ?u8, source_index: usize, target_index: usize) void {
        if (source_index >= sub_image.pixels.len) {
            return;
        }

        switch (current_frame.pixels) {
            .indexed1 => |pixels| {
                if (target_index >= pixels.indices.len) {
                    return;
                }

                if (transparency_index_opt) |transparency_index| {
                    if (sub_image.pixels[source_index] == transparency_index) {
                        return;
                    }
                }

                pixels.indices[target_index] = @truncate(sub_image.pixels[source_index]);
            },
            .indexed2 => |pixels| {
                if (target_index >= pixels.indices.len) {
                    return;
                }

                if (transparency_index_opt) |transparency_index| {
                    if (sub_image.pixels[source_index] == transparency_index) {
                        return;
                    }
                }

                pixels.indices[target_index] = @truncate(sub_image.pixels[source_index]);
            },
            .indexed4 => |pixels| {
                if (target_index >= pixels.indices.len) {
                    return;
                }

                if (transparency_index_opt) |transparency_index| {
                    if (sub_image.pixels[source_index] == transparency_index) {
                        return;
                    }
                }

                pixels.indices[target_index] = @truncate(sub_image.pixels[source_index]);
            },
            .indexed8 => |pixels| {
                if (target_index >= pixels.indices.len) {
                    return;
                }

                if (transparency_index_opt) |transparency_index| {
                    if (sub_image.pixels[source_index] == transparency_index) {
                        return;
                    }
                }

                pixels.indices[target_index] = @intCast(sub_image.pixels[source_index]);
            },
            .rgb24 => |pixels| {
                if (target_index >= pixels.len) {
                    return;
                }

                if (transparency_index_opt) |transparency_index| {
                    if (sub_image.pixels[source_index] == transparency_index) {
                        return;
                    }
                }

                const pixel_index = sub_image.pixels[source_index];
                if (pixel_index < effective_color_table.len) {
                    pixels[target_index] = effective_color_table[pixel_index];
                }
            },
            .rgba32 => |pixels| {
                if (target_index >= pixels.len) {
                    return;
                }

                if (transparency_index_opt) |transparency_index| {
                    if (sub_image.pixels[source_index] == transparency_index) {
                        return;
                    }
                }

                const pixel_index = sub_image.pixels[source_index];
                if (pixel_index < effective_color_table.len) {
                    pixels[target_index] = color.Rgba32.fromU32Rgba(effective_color_table[pixel_index].toU32Rgba());
                }
            },
            else => {
                std.debug.panic("Pixel format {s} not supported", .{@tagName(current_frame.pixels)});
            },
        }
    }

    fn allocNewFrame(self: *GIF) !*FrameData {
        var new_frame = try self.frames.addOne(self.allocator);
        new_frame.* = FrameData{};
        return new_frame;
    }

    fn createNewAnimationFrame(self: *const GIF, pixel_format: PixelFormat) !Image.AnimationFrame {
        var new_frame = Image.AnimationFrame{
            .pixels = try color.PixelStorage.init(self.allocator, pixel_format, @as(usize, @intCast(self.header.width * self.header.height))),
            .duration = 0.0,
        };

        // Set all pixels to all zeroes
        switch (new_frame.pixels) {
            .indexed1 => |pixels| @memset(pixels.indices, 0),
            .indexed2 => |pixels| @memset(pixels.indices, 0),
            .indexed4 => |pixels| @memset(pixels.indices, 0),
            .indexed8 => |pixels| @memset(pixels.indices, 0),
            .rgb24 => |pixels| @memset(pixels, color.Rgb24.fromU32Rgb(0)),
            .rgba32 => |pixels| @memset(pixels, color.Rgba32.fromU32Rgba(0)),
            else => std.debug.panic("Pixel format {} not supported", .{pixel_format}),
        }

        return new_frame;
    }

    fn findBestPixelFormat(self: *const GIF) PixelFormat {
        var total_color_count: usize = 0;

        if (self.header.flags.use_global_color_table) {
            total_color_count = @as(usize, 1) << (@as(u6, @intCast(self.header.flags.global_color_table_size)) + 1);
        }

        var use_transparency: bool = false;

        var max_color_per_frame: usize = 0;

        for (self.frames.items) |frame| {
            if (frame.graphics_control) |graphic_control| {
                if (graphic_control.flags.has_transparent_color) {
                    use_transparency = true;
                }
            }

            var color_per_frame: usize = 0;

            for (frame.sub_images.items) |sub_image| {
                if (sub_image.image_descriptor.flags.has_local_color_table) {
                    color_per_frame += @as(usize, 1) << (@as(u6, @intCast(sub_image.image_descriptor.flags.local_color_table_size)) + 1);
                }
            }

            max_color_per_frame = @max(max_color_per_frame, color_per_frame);
        }

        total_color_count += max_color_per_frame;

        // TODO: Handle indexed format with transparency
        if (total_color_count <= (1 << 1)) {
            return .indexed1;
        } else if (total_color_count <= (1 << 2)) {
            return .indexed2;
        } else if (total_color_count <= (1 << 4)) {
            return .indexed4;
        } else if (total_color_count <= (1 << 8)) {
            return .indexed8;
        }

        if (use_transparency) {
            return .rgba32;
        }

        return .rgb24;
    }
};
