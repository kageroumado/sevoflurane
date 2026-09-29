// File streams and a zstd decompressor for HDiffPatch's patch_decompress.
// The decompressor follows the zstd plugin in HDiffPatch's
// decompress_plugin_demo.h (MIT, Copyright (c) 2012-2025 housisong).

#include "sophon_hpatch.h"

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "hpatch/patch.h"
#include "zstd.h"

// MARK: - File streams

typedef struct {
    int fd;
} file_stream;

static hpatch_BOOL file_read(const hpatch_TStreamInput *stream, hpatch_StreamPos_t pos,
                             unsigned char *out, unsigned char *out_end) {
    const file_stream *file = (const file_stream *)stream->streamImport;
    size_t wanted = (size_t)(out_end - out);
    while (wanted > 0) {
        ssize_t got = pread(file->fd, out, wanted, (off_t)pos);
        if (got <= 0) return hpatch_FALSE;
        out += got;
        pos += (hpatch_StreamPos_t)got;
        wanted -= (size_t)got;
    }
    return hpatch_TRUE;
}

static hpatch_BOOL file_write(const hpatch_TStreamOutput *stream, hpatch_StreamPos_t pos,
                              const unsigned char *data, const unsigned char *data_end) {
    const file_stream *file = (const file_stream *)stream->streamImport;
    size_t left = (size_t)(data_end - data);
    while (left > 0) {
        ssize_t put = pwrite(file->fd, data, left, (off_t)pos);
        if (put <= 0) return hpatch_FALSE;
        data += put;
        pos += (hpatch_StreamPos_t)put;
        left -= (size_t)put;
    }
    return hpatch_TRUE;
}

static hpatch_BOOL empty_read(const hpatch_TStreamInput *stream, hpatch_StreamPos_t pos,
                              unsigned char *out, unsigned char *out_end) {
    (void)stream;
    (void)pos;
    return out == out_end;
}

static int open_input(const char *path, hpatch_TStreamInput *stream, file_stream *file) {
    struct stat info;
    file->fd = open(path, O_RDONLY);
    if (file->fd < 0) return 0;
    if (fstat(file->fd, &info) != 0) {
        close(file->fd);
        return 0;
    }
    memset(stream, 0, sizeof(*stream));
    stream->streamImport = file;
    stream->streamSize = (hpatch_StreamPos_t)info.st_size;
    stream->read = file_read;
    return 1;
}

// MARK: - zstd

typedef struct {
    const hpatch_TStreamInput *code_stream;
    hpatch_StreamPos_t code_begin;
    hpatch_StreamPos_t code_end;
    ZSTD_inBuffer input;
    ZSTD_outBuffer output;
    size_t data_begin;
    ZSTD_DStream *stream;
    unsigned char buffer[1];
} zstd_decoder;

static hpatch_BOOL zstd_can_open(const char *type) { return strcmp(type, "zstd") == 0; }

static hpatch_decompressHandle zstd_open(hpatch_TDecompress *plugin, hpatch_StreamPos_t data_size,
                                         const hpatch_TStreamInput *code_stream,
                                         hpatch_StreamPos_t code_begin, hpatch_StreamPos_t code_end) {
    (void)data_size;
    size_t in_size = ZSTD_DStreamInSize();
    size_t out_size = ZSTD_DStreamOutSize();
    zstd_decoder *self = malloc(sizeof(zstd_decoder) + in_size + out_size);
    if (!self) {
        _hpatch_update_decError(plugin, hpatch_dec_mem_error);
        return 0;
    }
    memset(self, 0, sizeof(zstd_decoder));
    self->code_stream = code_stream;
    self->code_begin = code_begin;
    self->code_end = code_end;
    self->input.src = self->buffer;
    self->input.size = in_size;
    self->input.pos = in_size;
    self->output.dst = self->buffer + in_size;
    self->output.size = out_size;
    self->stream = ZSTD_createDStream();
    if (!self->stream || ZSTD_isError(ZSTD_initDStream(self->stream))) {
        if (self->stream) ZSTD_freeDStream(self->stream);
        free(self);
        _hpatch_update_decError(plugin, hpatch_dec_open_error);
        return 0;
    }
    // HDiffPatch writes zstd frames with windows up to 2^30.
    ZSTD_DCtx_setParameter(self->stream, ZSTD_d_windowLogMax, 30);
    return self;
}

static hpatch_BOOL zstd_close(hpatch_TDecompress *plugin, hpatch_decompressHandle handle) {
    (void)plugin;
    zstd_decoder *self = handle;
    if (!self) return hpatch_TRUE;
    ZSTD_freeDStream(self->stream);
    free(self);
    return hpatch_TRUE;
}

static hpatch_BOOL zstd_part(hpatch_decompressHandle handle, unsigned char *out,
                             unsigned char *out_end) {
    zstd_decoder *self = handle;
    while (out < out_end) {
        size_t ready = self->output.pos - self->data_begin;
        if (ready > 0) {
            if (ready > (size_t)(out_end - out)) ready = (size_t)(out_end - out);
            memcpy(out, (const unsigned char *)self->output.dst + self->data_begin, ready);
            out += ready;
            self->data_begin += ready;
            continue;
        }
        if (self->input.pos == self->input.size) {
            self->input.pos = 0;
            if (self->input.size > self->code_end - self->code_begin)
                self->input.size = (size_t)(self->code_end - self->code_begin);
            if (self->input.size > 0) {
                unsigned char *src = (unsigned char *)self->input.src;
                if (!self->code_stream->read(self->code_stream, self->code_begin, src,
                                             src + self->input.size))
                    return hpatch_FALSE;
                self->code_begin += self->input.size;
            }
        }
        self->output.pos = 0;
        self->data_begin = 0;
        size_t status = ZSTD_decompressStream(self->stream, &self->output, &self->input);
        if (ZSTD_isError(status) || self->output.pos == 0) return hpatch_FALSE;
    }
    return hpatch_TRUE;
}

// MARK: - Apply

sophon_hpatch_result sophon_hpatch_apply(const char *old_path, const char *diff_path,
                                         const char *new_path) {
    file_stream old_file = {-1}, diff_file = {-1}, new_file = {-1};
    hpatch_TStreamInput old_stream, diff_stream;
    hpatch_TStreamOutput new_stream;
    hpatch_compressedDiffInfo info;
    sophon_hpatch_result result = SOPHON_HPATCH_OK;

    if (old_path) {
        if (!open_input(old_path, &old_stream, &old_file)) return SOPHON_HPATCH_OPEN_OLD;
    } else {
        memset(&old_stream, 0, sizeof(old_stream));
        old_stream.read = empty_read;
    }
    if (!open_input(diff_path, &diff_stream, &diff_file)) {
        result = SOPHON_HPATCH_OPEN_DIFF;
        goto done;
    }
    if (!getCompressedDiffInfo(&info, &diff_stream)) {
        result = SOPHON_HPATCH_BAD_DIFF;
        goto done;
    }
    hpatch_TDecompress zstd_plugin = {zstd_can_open, zstd_open, zstd_close, zstd_part};
    hpatch_TDecompress *plugin = 0;
    if (info.compressedCount > 0) {
        if (!zstd_can_open(info.compressType)) {
            result = SOPHON_HPATCH_UNSUPPORTED_COMPRESSION;
            goto done;
        }
        plugin = &zstd_plugin;
    }
    if (info.oldDataSize != old_stream.streamSize) {
        result = SOPHON_HPATCH_OLD_SIZE;
        goto done;
    }
    new_file.fd = open(new_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (new_file.fd < 0) {
        result = SOPHON_HPATCH_OPEN_NEW;
        goto done;
    }
    memset(&new_stream, 0, sizeof(new_stream));
    new_stream.streamImport = &new_file;
    new_stream.streamSize = info.newDataSize;
    new_stream.write = file_write;

    enum { cache_size = 1 << 20 };
    unsigned char *cache = malloc(cache_size);
    if (!cache) {
        result = SOPHON_HPATCH_FAILED;
        goto done;
    }
    if (!patch_decompress_with_cache(&new_stream, &old_stream, &diff_stream, plugin, cache,
                                     cache + cache_size))
        result = SOPHON_HPATCH_FAILED;
    free(cache);

done:
    if (old_file.fd >= 0) close(old_file.fd);
    if (diff_file.fd >= 0) close(diff_file.fd);
    if (new_file.fd >= 0) close(new_file.fd);
    return result;
}
