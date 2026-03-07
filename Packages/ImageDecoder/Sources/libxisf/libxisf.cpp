/************************************************************************
 * LibXISF - library to load and save XISF files                        *
 * Copyright (C) 2023 Dušan Poizl                                       *
 *                                                                      *
 * This program is free software: you can redistribute it and/or modify *
 * it under the terms of the GNU General Public License as published by *
 * the Free Software Foundation, either version 3 of the License, or    *
 * (at your option) any later version.                                  *
 *                                                                      *
 * This program is distributed in the hope that it will be useful,      *
 * but WITHOUT ANY WARRANTY; without even the implied warranty of       *
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the        *
 * GNU General Public License for more details.                         *
 *                                                                      *
 * You should have received a copy of the GNU General Public License    *
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.*
 ************************************************************************/

#include "libxisf.h"
#include <unordered_map>
#include <unordered_set>
#include <cstring>
#include <iostream>
#include <sstream>
#include <cstdlib>
#include <cmath>
#include <lz4.h>
#include <lz4hc.h>
#include <pugixml.hpp>
#include <zlib.h>
#ifdef HAVE_ZSTD
#include <zstd.h>
#endif
#include "streambuffer.h"

namespace LibXISF
{

std::vector<std::string> splitString(const std::string &str, char delimiter);
void deserializeVariant(const pugi::xml_node &node, Variant &variant, const ByteArray &data);
void serializeVariant(pugi::xml_node &node, const Variant &variant);
Variant variantFromString(Variant::Type type, const String &str);

static std::unordered_map<String, Image::Type> imageTypeToEnum;
static std::unordered_map<Image::Type, String> imageTypeToString;
static std::unordered_map<String, Image::SampleFormat> sampleFormatToEnum;
static std::unordered_map<Image::SampleFormat, String> sampleFormatToString;
static std::unordered_map<String, Image::ColorSpace> colorSpaceToEnum;
static std::unordered_map<Image::ColorSpace, String> colorSpaceToString;
static DataBlock::CompressionCodec compressionCodecOverride = DataBlock::None;
static bool byteShuffleOverride = false;
static int compressionLevelOverride = -1;
const size_t GiB = 1073741824;

static const std::unordered_map<String, std::pair<String, Variant::Type>> fitsNameToPropertyIdTypeConvert = {
    {"OBSERVER", {"Observer:Name", Variant::Type::String}},
    {"RADECSYS", {"Observation:CelestialReferenceSystem", Variant::Type::String}},
    {"CRVAL1",   {"Observation:Center:Dec", Variant::Type::Float64}},
    {"CRVAL2",   {"Observation:Center:RA", Variant::Type::Float64}},
    {"CRPIX1",   {"Observation:Center:X", Variant::Type::Float64}},
    {"CRPIX2",   {"Observation:Center:Y", Variant::Type::Float64}},
    {"EQUINOX",  {"Observation:Equinox", Variant::Type::Float64}},
    {"SITELAT",  {"Observation:Location:Latitude", Variant::Type::Float64}},
    {"SITELONG", {"Observation:Location:Longitude", Variant::Type::Float64}},
    {"OBJECT",   {"Observation:Object:Name", Variant::Type::String}},
    {"DEC",      {"Observation:Object:Dec", Variant::Type::Float64}},
    {"RA",       {"Observation:Object:RA", Variant::Type::Float64}},
    {"DATE-OBS", {"Observation:Time:Start", Variant::Type::TimePoint}},
    {"DATE-END", {"Observation:Time:End", Variant::Type::TimePoint}},
    {"GAIN",     {"Instrument:Camera:Gain", Variant::Type::Float32}},
    {"ISOSPEED", {"Instrument:Camera:ISOSpeed", Variant::Type::Int32}},
    {"INSTRUME", {"Instrument:Camera:Name", Variant::Type::String}},
    {"ROTATANG", {"Instrument:Camera:Rotation", Variant::Type::Float32}},
    {"XBINNING", {"Instrument:Camera:XBinning", Variant::Type::Int32}},
    {"YBINNING", {"Instrument:Camera:YBinning", Variant::Type::Int32}},
    {"EXPTIME",  {"Instrument:ExposureTime", Variant::Type::Float32}},
    {"FILTER",   {"Instrument:Filter:Name", Variant::Type::String}},
    {"FOCUSPOS", {"Instrument:Focuser:Position", Variant::Type::Float32}},
    {"CCD-TEMP", {"Instrument:Sensor:Temperature", Variant::Type::Float32}},
    {"APTDIA",   {"Instrument:Telescope:Aperture", Variant::Type::Float32}},
    {"FOCALLEN", {"Instrument:Telescope:FocalLength", Variant::Type::Float32}},
    {"TELESCOP", {"Instrument:Telescope:Name", Variant::Type::String}},
};

static void byteShuffle(ByteArray &data, int itemSize)
{
    if(itemSize > 1)
    {
        ByteArray &input = data;
        ByteArray output(input.size());
        size_t num = input.size() / itemSize;
        char *s = output.data();
        for(int i=0; i<itemSize; i++)
        {
            const char *u = input.constData() + i;
            for(size_t o=0; o<num; o++, s++, u += itemSize)
                *s = *u;
        }
        memcpy(s, input.constData() + num * itemSize, input.size() % itemSize);
        data = output;
    }
}

#ifdef __SSE2__
#include <x86intrin.h>

template<int itemSize>
size_t byteUnshuffleSSE(const char *in, char *out, size_t num)
{
    //size_t size = num;
    const __m128i *_in[4] = {(const __m128i*)in,
                             (const __m128i*)(in + num),
                             (const __m128i*)(in + num * 2),
                             (const __m128i*)(in + num * 3)};
    __m128i *_out = (__m128i*)out;
    num /= 16;

    for(size_t i = 0; i < num; i++)
    {
        if constexpr(itemSize == 4)
        {
            __m128i a = _mm_loadu_si128(_in[0] + i);
            __m128i b = _mm_loadu_si128(_in[1] + i);
            __m128i c = _mm_loadu_si128(_in[2] + i);
            __m128i d = _mm_loadu_si128(_in[3] + i);
            __m128i x = _mm_unpacklo_epi8(a, b);
            __m128i y = _mm_unpackhi_epi8(a, b);
            __m128i z = _mm_unpacklo_epi8(c, d);
            __m128i w = _mm_unpackhi_epi8(c, d);
            _mm_storeu_si128(_out + i * 4, _mm_unpacklo_epi16(x, z));
            _mm_storeu_si128(_out + i * 4 + 1, _mm_unpackhi_epi16(x, z));
            _mm_storeu_si128(_out + i * 4 + 2, _mm_unpacklo_epi16(y, w));
            _mm_storeu_si128(_out + i * 4 + 3, _mm_unpackhi_epi16(y, w));
        }
        if constexpr(itemSize == 2)
        {
            __m128i a = _mm_loadu_si128(_in[0] + i);
            __m128i b = _mm_loadu_si128(_in[1] + i);
            __m128i x = _mm_unpacklo_epi8(a, b);
            __m128i y = _mm_unpackhi_epi8(a, b);
            _mm_storeu_si128(_out + i * 2, x);
            _mm_storeu_si128(_out + i * 2 + 1, y);
        }
    }
    return num * 16 * itemSize;
}
#endif

static void byteUnshuffle(ByteArray &data, int itemSize)
{
    if(itemSize > 1)
    {
        ByteArray &input = data;
        ByteArray output(input.size());
        size_t num = input.size() / itemSize;
        size_t off = 0;
#ifdef __SSE2__
        if(itemSize == 4)
            off = byteUnshuffleSSE<4>(input.data(), output.data(), num);
        if(itemSize == 2)
            off = byteUnshuffleSSE<2>(input.data(), output.data(), num);
#endif

        const char *s = input.constData() + off;
        for(int i=0; i<itemSize; i++)
        {
            char *u = output.data() + i + off;
            for(size_t o = off / itemSize; o < num; o++, s++, u += itemSize)
                *u = *s;
        }
        memcpy(output.data() + num * itemSize, s, input.size() % itemSize);
        data = output;
    }
}

void DataBlock::decompress(const ByteArray &input, const String &encoding)
{
    ByteArray tmp = input;

    if(encoding == "base64")
        tmp.decodeBase64();
    else if(encoding == "base16")
        tmp.decodeHex();

    if(subblocks.size() == 0)
        subblocks.push_back({tmp.size(), uncompressedSize});

    switch(codec)
    {
    case None:
        data = std::move(tmp);
        break;
    case Zlib:
    {
        data.resize(uncompressedSize);
        const char *srcPtr = tmp.constData();
        char *dstPtr = data.data();
        for(auto &block : subblocks)
        {
            uLongf size = block.second;
            ::uncompress((Bytef*)dstPtr, &size, (const Bytef*)srcPtr, block.first);
            srcPtr += block.first;
            dstPtr += block.second;
        }
        break;
    }
    case LZ4:
    case LZ4HC:
    {
        data.resize(uncompressedSize);
        const char *srcPtr = tmp.constData();
        char *dstPtr = data.data();
        for(auto &block : subblocks)
        {
            if(LZ4_decompress_safe(srcPtr, dstPtr, block.first, block.second) < 0)
                throw Error("LZ4 decompression failed");
            srcPtr += block.first;
            dstPtr += block.second;
        }
        break;
    }
    case ZSTD:
#ifdef HAVE_ZSTD
    {
        data.resize(uncompressedSize);
        const char *srcPtr = tmp.constData();
        char *dstPtr = data.data();
        for(auto &block : subblocks)
        {
            if(ZSTD_isError(ZSTD_decompress(dstPtr, block.second, srcPtr, block.first)))
                throw Error("ZSTD decompression failed");
            srcPtr += block.first;
            dstPtr += block.second;
        }

    }
#else
        throw Error("ZSTD support not compiled");
#endif
        break;
    }

    subblocks.clear();

    byteUnshuffle(data, byteShuffling);
    attachmentPos = 0;
}

void DataBlock::compress(int sampleFormatSize)
{
    ByteArray tmp = data;
    uncompressedSize = data.size();

    if (compressionCodecOverride != CompressionCodec::None)
    {
        codec = compressionCodecOverride;
        byteShuffling = sampleFormatSize;
        compressLevel = compressionLevelOverride;
    }

    byteShuffle(tmp, byteShuffling);

    switch(codec)
    {
    case None:
        data = tmp;
        break;
    case Zlib:
    {
        int64_t size = tmp.size();
        int64_t compSize = 0;
        int64_t inPtr = 0;
        while(inPtr < size)
        {
            int64_t inSize = UINT32_MAX < size - inPtr ? UINT32_MAX : size - inPtr;
            data.resize(compSize + compressBound(inSize));
            uLongf outSize = data.size() - compSize;
            if(::compress2((Bytef*)data.data() + compSize, &outSize, (const Bytef*)tmp.constData() + inPtr, inSize, compressLevel) != Z_OK)
                throw Error("Zlib compression failed");

            compSize += outSize;
            inPtr += inSize;
            subblocks.push_back({outSize, inSize});
        }
        data.resize(compSize);
        break;
    }
    case LZ4:
    case LZ4HC:
    {
        int64_t size = tmp.size();
        int64_t compSize = 0;
        int64_t inPtr = 0;
        while(inPtr < size)
        {
            int64_t inSize = LZ4_MAX_INPUT_SIZE < size - inPtr ? LZ4_MAX_INPUT_SIZE : size - inPtr;
            data.resize(compSize + LZ4_compressBound(inSize));
            int outSize = 0;

            if(codec == LZ4)
                outSize = LZ4_compress_default(tmp.constData() + inPtr, data.data() + compSize, inSize, data.size() - compSize);
            else
                outSize = LZ4_compress_HC(tmp.constData() + inPtr, data.data() + compSize, inSize, data.size() - compSize, compressLevel < 0 ? LZ4HC_CLEVEL_DEFAULT : compressLevel);

            if(outSize <= 0)
                throw Error("LZ4 compression failed");

            compSize += outSize;
            inPtr += inSize;
            subblocks.push_back({outSize, inSize});
        }
        data.resize(compSize);
        break;
    }
    case ZSTD:
    {
#ifdef HAVE_ZSTD
        size_t compSize = 0;
        data.resize(ZSTD_compressBound(uncompressedSize));
        compSize = ZSTD_compress(data.data(), data.size(), tmp.data(), tmp.size(), compressLevel < 0 ? ZSTD_CLEVEL_DEFAULT : compressLevel);
        if(ZSTD_isError(compSize))
            throw Error("ZSTD compression failed");

        data.resize(compSize);
#else
        throw Error("ZSTD support not compiled");
#endif
        break;
    }
    }
}

bool DataBlock::CompressionCodecSupported(CompressionCodec codec)
{
    (void)codec;
#ifndef HAVE_ZSTD
    if(codec == ZSTD)
        return false;
#endif
    return true;
}

Property::Property(const String &_id, const char *_value) :
    id(_id),
    value(_value)
{
}

template<typename T>
void planarToNormal(void *_in, void *_out, size_t channels, size_t size)
{
    T *in = static_cast<T*>(_in);
    T *out = static_cast<T*>(_out);
    for(size_t i=0; i<size; i++)
        for(size_t o=0; o<channels; o++)
            out[i*channels + o] = in[o*size + i];
}

template<typename T>
void normalToPlanar(void *_in, void *_out, size_t channels, size_t size)
{
    T *in = static_cast<T*>(_in);
    T *out = static_cast<T*>(_out);
    for(size_t i=0; i<size; i++)
        for(size_t o=0; o<channels; o++)
            out[o*size + i] = in[i*channels + o];
}

Image::Image(uint64_t width, uint64_t height, uint64_t channelCount, SampleFormat sampleFormat, ColorSpace colorSpace, PixelStorage pixelStorate) :
    _pixelStorage(pixelStorate),
    _sampleFormat(sampleFormat),
    _colorSpace(colorSpace)
{
    setGeometry(width, height, channelCount);
}

uint64_t Image::width() const
{
    return _width;
}

uint64_t Image::height() const
{
    return _height;
}

uint64_t Image::channelCount() const
{
    return _channelCount;
}

void Image::setGeometry(uint64_t width, uint64_t height, uint64_t channelCount)
{
    _width = width;
    _height = height;
    _channelCount = channelCount;
    _dataBlock.data.resize(width * height * channelCount * sampleFormatSize(_sampleFormat));
}

const Bounds &Image::bounds() const
{
    return _bounds;
}

void Image::setBounds(const Bounds &newBounds)
{
    _bounds = newBounds;
}

Image::Type Image::imageType() const
{
    return _imageType;
}

void Image::setImageType(Type newImageType)
{
    _imageType = newImageType;
}

Image::PixelStorage Image::pixelStorage() const
{
    return _pixelStorage;
}

void Image::setPixelStorage(PixelStorage newPixelStorage)
{
    _pixelStorage = newPixelStorage;
}

Image::SampleFormat Image::sampleFormat() const
{
    return _sampleFormat;
}

void Image::setSampleFormat(SampleFormat newSampleFormat)
{
    _sampleFormat = newSampleFormat;
    if(_dataBlock.byteShuffling)_dataBlock.byteShuffling = sampleFormatSize(_sampleFormat);
    _dataBlock.data.resize(_width * _height * _channelCount * sampleFormatSize(_sampleFormat));
}

Image::ColorSpace Image::colorSpace() const
{
    return _colorSpace;
}

void Image::setColorSpace(ColorSpace newColorSpace)
{
    _colorSpace = newColorSpace;
}

const ColorFilterArray Image::colorFilterArray() const
{
    return _cfa;
}

void Image::setColorFilterArray(const ColorFilterArray cfa)
{
    _cfa = cfa;
}

const std::vector<Property>& Image::imageProperties() const
{
    return _properties;
}

void Image::addProperty(const Property &property)
{
    if(_propertiesId.count(property.id))
        throw Error("Duplicate property id");

    _propertiesId[property.id] = _properties.size();
    _properties.push_back(property);
}

void Image::updateProperty(const Property &property)
{
    if(!_propertiesId.count(property.id))
        addProperty(property);
    else
        _properties[_propertiesId[property.id]] = property;
}

const std::vector<FITSKeyword> Image::fitsKeywords() const
{
    return _fitsKeywords;
}

void Image::addFITSKeyword(const FITSKeyword &keyword)
{
    _fitsKeywords.push_back(keyword);
}

bool Image::addFITSKeywordAsProperty(const String &name, const String &value)
{
    if(fitsNameToPropertyIdTypeConvert.count(name))
    {
        auto &c = fitsNameToPropertyIdTypeConvert.at(name);
        Property prop(c.first, variantFromString(c.second, value));

        if(name == "APTDIA" || name == "FOCALLEN")
            prop.value.value<LibXISF::Float32>() /= 1000.0f;

        updateProperty(prop);
        return true;
    }
    return false;
}

const ByteArray &Image::iccProfile() const
{
    return _iccProfile;
}

void Image::setIccProfile(const ByteArray &iccProfile)
{
    _iccProfile = iccProfile;
}

void *Image::imageData()
{
    return _dataBlock.data.size() ? _dataBlock.data.data() : nullptr;
}

const void *Image::imageData() const
{
    return _dataBlock.data.size() ? _dataBlock.data.data() : nullptr;
}

size_t Image::imageDataSize() const
{
    return _dataBlock.data.size();
}

DataBlock::CompressionCodec Image::compression() const
{
    return _dataBlock.codec;
}

void Image::setCompression(DataBlock::CompressionCodec compression, int level)
{
    _dataBlock.codec = compression;
    _dataBlock.compressLevel = -1;

    level = std::min(std::max(level, -1), 100);

    auto percentToRange = [](int val, int min, int max)
    {
        double slope = (max - min) / 100.0;
        return std::round(min + slope * val);
    };

    if(level >= 0)
    {
        switch(compression)
        {
        case DataBlock::CompressionCodec::Zlib:
            _dataBlock.compressLevel = percentToRange(level, Z_BEST_SPEED, Z_BEST_COMPRESSION);
            break;
        case DataBlock::CompressionCodec::LZ4:
        case DataBlock::CompressionCodec::LZ4HC:
            _dataBlock.compressLevel = percentToRange(level, 1, LZ4HC_CLEVEL_MAX);
            break;
        case DataBlock::CompressionCodec::ZSTD:
#ifdef HAVE_ZSTD
            _dataBlock.compressLevel = percentToRange(level, 0, ZSTD_maxCLevel());
#endif
            break;
        default:
            //nothing
            break;
        }
    }
}

bool Image::byteShuffling() const
{
    return _dataBlock.byteShuffling;
}

void Image::setByteshuffling(bool enable)
{
    _dataBlock.byteShuffling = enable ? sampleFormatSize(_sampleFormat) : 0;
}

void Image::convertPixelStorageTo(PixelStorage storage)
{
    if(_pixelStorage == storage || _channelCount <= 1)
    {
        _pixelStorage = storage;
        return;
    }

    ByteArray tmp;
    tmp.resize(_dataBlock.data.size());
    size_t size = _width*_height;

    switch(_sampleFormat)
    {
    case UInt8:
        if(storage == Normal)
            planarToNormal<uint8_t>(_dataBlock.data.data(), tmp.data(), _channelCount, size);
        else
            normalToPlanar<uint8_t>(_dataBlock.data.data(), tmp.data(), _channelCount, size);
        break;
    case UInt16:
        if(storage == Normal)
            planarToNormal<uint16_t>(_dataBlock.data.data(), tmp.data(), _channelCount, size);
        else
            normalToPlanar<uint16_t>(_dataBlock.data.data(), tmp.data(), _channelCount, size);
        break;
    case UInt32:
    case Float32:
        if(storage == Normal)
            planarToNormal<uint32_t>(_dataBlock.data.data(), tmp.data(), _channelCount, size);
        else
            normalToPlanar<uint32_t>(_dataBlock.data.data(), tmp.data(), _channelCount, size);
        break;
    case UInt64:
    case Float64:
        if(storage == Normal)
            planarToNormal<uint64_t>(_dataBlock.data.data(), tmp.data(), _channelCount, size);
        else
            normalToPlanar<uint64_t>(_dataBlock.data.data(), tmp.data(), _channelCount, size);
        break;
    default:
        break;
    }
    _dataBlock.data = tmp;
    _pixelStorage = storage;
}

Image::Type Image::imageTypeEnum(const String &type)
{
    auto t = imageTypeToEnum.find(type);
    return t != imageTypeToEnum.end() ? t->second : Image::Light;
}

String Image::imageTypeString(Type type)
{
    auto t = imageTypeToString.find(type);
    return t != imageTypeToString.end() ? t->second : "Light";
}

Image::PixelStorage Image::pixelStorageEnum(const String &storage)
{
    if(storage == "Normal")return Image::Normal;
    return Image::Planar;
}

String Image::pixelStorageString(PixelStorage storage)
{
    if(storage == Normal)return "Normal";
    return "Planar";
}

Image::SampleFormat Image::sampleFormatEnum(const String &format)
{
    auto t = sampleFormatToEnum.find(format);
    return t != sampleFormatToEnum.end() ? t->second : Image::UInt16;
}

String Image::sampleFormatString(SampleFormat format)
{
    auto t = sampleFormatToString.find(format);
    return t != sampleFormatToString.end() ? t->second : "UInt16";
}

Image::ColorSpace Image::colorSpaceEnum(const String &colorSpace)
{
    auto t = colorSpaceToEnum.find(colorSpace);
    return t != colorSpaceToEnum.end() ? t->second : Image::Gray;
}

String Image::colorSpaceString(ColorSpace colorSpace)
{
    auto t = colorSpaceToString.find(colorSpace);
    return t != colorSpaceToString.end() ? t->second : "Gray";
}

size_t Image::sampleFormatSize(SampleFormat sampleFormat)
{
    switch(sampleFormat)
    {
        case Image::UInt8:   return sizeof(LibXISF::UInt8);
        case Image::UInt16:  return sizeof(LibXISF::UInt16);
        case Image::UInt32:  return sizeof(LibXISF::UInt32);
        case Image::UInt64:  return sizeof(LibXISF::UInt64);
        case Image::Float32: return sizeof(LibXISF::Float32);
        case Image::Float64: return sizeof(LibXISF::Float64);
        case Image::Complex32: return sizeof(LibXISF::Complex32);
        case Image::Complex64: return sizeof(LibXISF::Complex64);
    }
    return sizeof(UInt16);
}

class XISFReaderPrivate
{
public:
    void open(const String &name);
    void open(const ByteArray &data);
    /** Open image from istream. This method takes ownership of *io pointer */
    void open(std::istream *io);
    /** Close opended file release all data. */
    void close();
    /** Return number of images inside file */
    int imagesCount() const;
    /** Return reference to Image
     *  @param n index of image
     *  @param readPixel when false it will read pixel data from file and imageData()
     *  will return nullptr */
    const Image& getImage(uint32_t n, bool readPixels = true);
    const Image& getThumbnail();
private:
    void readXISFHeader();
    void readSignature();
    void parseCompression(const pugi::xml_node &node, DataBlock &dataBlock);
    DataBlock parseDataBlock(const pugi::xml_node &node);
    Property parseProperty(const pugi::xml_node &node);
    FITSKeyword parseFITSKeyword(const pugi::xml_node &node);
    ColorFilterArray parseCFA(const pugi::xml_node &node);
    Image parseImage(const pugi::xml_node &node);
    void readAttachment(DataBlock &dataBlock);

    std::unique_ptr<std::istream> _io;
    std::unique_ptr<StreamBuffer> _buffer;
    std::vector<Image> _images;
    Image _thumbnail;
    std::vector<Property> _properties;
};

void XISFReaderPrivate::open(const String &name)
{
    close();
    _io = std::make_unique<std::ifstream>(name.c_str(), std::ios_base::in | std::ios_base::binary);
    readSignature();
    readXISFHeader();
}

void XISFReaderPrivate::open(const ByteArray &data)
{
    close();
    _buffer = std::make_unique<StreamBuffer>(data);
    _io = std::make_unique<std::istream>(_buffer.get());
    readSignature();
    readXISFHeader();
}

void XISFReaderPrivate::open(std::istream *io)
{
    close();
    _io.reset(io);
    readSignature();
    readXISFHeader();
}

void XISFReaderPrivate::close()
{
    _io.reset();
    _buffer.reset();
    _images.clear();
    _properties.clear();
}

int XISFReaderPrivate::imagesCount() const
{
    return _images.size();
}

const Image& XISFReaderPrivate::getImage(uint32_t n, bool readPixels)
{
    if(n >= _images.size())
        throw Error("Out of bounds");

    Image &img = _images[n];
    if(img._dataBlock.attachmentPos && readPixels)
    {
        readAttachment(img._dataBlock);
    }
    return img;
}

const Image &XISFReaderPrivate::getThumbnail()
{
    Image &img = _thumbnail;
    if(_thumbnail._dataBlock.attachmentPos)
    {
        _io->seekg(img._dataBlock.attachmentPos);
        ByteArray data(img._dataBlock.attachmentSize);
        _io->read(data.data(), data.size());
        img._dataBlock.decompress(data);
    }
    return _thumbnail;
}

void XISFReaderPrivate::readXISFHeader()
{
    uint32_t headerLen[2] = {0};
    _io->read((char*)&headerLen, sizeof(headerLen));

    ByteArray xisfHeader(headerLen[0]);
    _io->read(xisfHeader.data(), headerLen[0]);

    pugi::xml_document doc;
    doc.load_buffer(xisfHeader.data(), xisfHeader.size());

    pugi::xml_node root = doc.child("xisf");

    if(root && root.attribute("version").as_string() == std::string("1.0"))
    {
        for(auto &image : root.children("Image"))
            _images.push_back(parseImage(image));

        for(auto &property : root.children("Property"))
            _properties.push_back(parseProperty(property));

        if(root.child("Thumbnail"))
            _thumbnail = parseImage(root.child("Thumbnail"));
    }
    else throw Error("Unknown root XML element");
}

void XISFReaderPrivate::readSignature()
{
    char signature[8];
    _io->read(signature, sizeof(signature));
    if(_io->fail())
        throw Error("Failed to read from file");

    if(memcmp(signature, "XISF0100", sizeof(signature)) != 0)
        throw Error("Not valid XISF 1.0 file");
}

void XISFReaderPrivate::parseCompression(const pugi::xml_node &node, DataBlock &dataBlock)
{
    std::vector<std::string> compression = splitString(node.attribute("compression").as_string(), ':');
    if(compression.size() >= 2)
    {
        if(compression[0].find("zlib") == 0)
            dataBlock.codec = DataBlock::Zlib;
        else if(compression[0].find("lz4hc") == 0)
            dataBlock.codec = DataBlock::LZ4HC;
        else if(compression[0].find("lz4") == 0)
            dataBlock.codec = DataBlock::LZ4;
#ifdef HAVE_ZSTD
        else if(compression[0].find("zstd") == 0)
            dataBlock.codec = DataBlock::ZSTD;
#endif
        else
            throw Error("Unknown compression codec");

        dataBlock.uncompressedSize = std::stoull(compression[1]);

        if(compression[0].find("+sh") != std::string::npos)
        {
            if(compression.size() == 3)
                dataBlock.byteShuffling = std::stoi(compression[2]);
            else
                throw Error("Missing byte shuffling size");
        }

        if(node.attribute("subblocks"))
        {
            std::vector<std::string> subblocks = splitString(node.attribute("subblocks").as_string(), ':');
            for(auto &block : subblocks)
            {
                size_t pos = 0;
                size_t comp = std::stoull(block, &pos);
                size_t deco = std::stoull(block.substr(pos+1));
                dataBlock.subblocks.push_back({comp, deco});
            }
        }
    }
}

DataBlock XISFReaderPrivate::parseDataBlock(const pugi::xml_node &node)
{
    DataBlock dataBlock;
    std::vector<std::string> location = splitString(node.attribute("location").as_string(), ':');

    parseCompression(node, dataBlock);

    if(location.size() && location[0] == "embedded")
    {
        dataBlock.embedded = true;
    }
    else if(location.size() >= 2 && location[0] == "inline")
    {
        ByteArray text(node.text().as_string());
        dataBlock.decompress(text, location[1]);
    }
    else if(location.size() >= 3 && location[0] == "attachment")
    {
        dataBlock.attachmentPos = std::stoull(location[1]);
        dataBlock.attachmentSize = std::stoull(location[2]);
    }
    else
    {
        throw Error("Invalid data block");
    }

    if(dataBlock.embedded)
    {
        auto dataNode = node.child("Data");
        if(dataNode)
        {
            parseCompression(dataNode, dataBlock);
            String encoding = dataNode.attribute("encoding").as_string();
            ByteArray text(dataNode.text().as_string());
            dataBlock.decompress(text, encoding);
        }
        else
            throw Error("Unexpected XML element");
    }

    return dataBlock;
}

Property XISFReaderPrivate::parseProperty(const pugi::xml_node &node)
{
    Property property;

    property.id = node.attribute("id").as_string();
    property.comment = node.attribute("comment").as_string();
    ByteArray data;
    if(node.attribute("location"))
    {
        DataBlock dataBlock = parseDataBlock(node);
        if(dataBlock.attachmentPos)
            readAttachment(dataBlock);

        data = dataBlock.data;
    }

    deserializeVariant(node, property.value, data);

    return property;
}

FITSKeyword XISFReaderPrivate::parseFITSKeyword(const pugi::xml_node &node)
{
    FITSKeyword fitsKeyword;
    fitsKeyword.name = node.attribute("name").as_string();
    fitsKeyword.value = node.attribute("value").as_string();
    fitsKeyword.comment = node.attribute("comment").as_string();
    return fitsKeyword;
}

ColorFilterArray XISFReaderPrivate::parseCFA(const pugi::xml_node &node)
{
    ColorFilterArray cfa;
    if(node.attribute("pattern") && node.attribute("width") && node.attribute("height"))
    {
        cfa.pattern = node.attribute("pattern").as_string();
        cfa.width = node.attribute("width").as_int();
        cfa.height = node.attribute("height").as_int();
    }
    else
    {
        throw Error("ColorFilterArray element missing one of mandatory attributes");
    }
    return cfa;
}

Image XISFReaderPrivate::parseImage(const pugi::xml_node &node)
{
    Image image;

    std::vector<std::string> geometry = splitString(node.attribute("geometry").as_string(), ':');
    if(geometry.size() != 3)throw Error("We support only 2D images");
    image._width = std::stoull(geometry[0]);
    image._height = std::stoull(geometry[1]);
    image._channelCount = std::stoull(geometry[2]);
    if(!image._width || !image._height || !image._channelCount)throw Error("Invalid image geometry");

    std::vector<std::string> bounds = splitString(node.attribute("bounds").as_string(), ':');
    if(bounds.size() == 2)
    {
        image._bounds.first = std::stod(bounds[0]);
        image._bounds.second = std::stod(bounds[1]);
    }
    image._imageType = Image::imageTypeEnum(node.attribute("imageType").as_string());
    image._pixelStorage = Image::pixelStorageEnum(node.attribute("pixelStorage").as_string());
    image._sampleFormat = Image::sampleFormatEnum(node.attribute("sampleFormat").as_string());
    image._colorSpace = Image::colorSpaceEnum(node.attribute("colorSpace").as_string());

    image._dataBlock = parseDataBlock(node);

    for(auto &property : node.children("Property"))
        image._properties.push_back(parseProperty(property));

    for(auto &fitsKeyword : node.children("FITSKeyword"))
        image._fitsKeywords.push_back(parseFITSKeyword(fitsKeyword));

    if(node.child("ColorFilterArray"))
        image._cfa = parseCFA(node.child("ColorFilterArray"));

    if(node.child("ICCProfile"))
    {
        DataBlock icc = parseDataBlock(node.child("ICCProfile"));
        if(icc.attachmentPos)
            readAttachment(icc);

        image._iccProfile = icc.data;
    }

    if(node.child("Thumbnail") && std::strcmp(node.name(), "Thumbnail"))
        _thumbnail = parseImage(node.child("Thumbnail"));

    return image;
}

void XISFReaderPrivate::readAttachment(DataBlock &dataBlock)
{
    ByteArray data(dataBlock.attachmentSize);
    _io->seekg(dataBlock.attachmentPos);
    size_t size = dataBlock.attachmentSize;
    char *ptr = data.data();
    while(size > 0)
    {
        size_t s = std::min(size, GiB);
        _io->read(ptr, s);
        size -= s;
        ptr += s;
    }
    dataBlock.decompress(data);
}

class  XISFWriterPrivate
{
public:
    void save(const String &name);
    void save(ByteArray &data);
    void save(std::ostream &io);
    void writeImage(const Image &image);
    static void writeFITSKeyword(pugi::xml_node &node, const FITSKeyword &keyword);
    static void writePropertyElement(pugi::xml_node &node, const Property &property);
private:
    void writeHeader();
    void writeImageElement(pugi::xml_node &node, const Image &image);
    void writeDataBlockAttributes(pugi::xml_node &image_node, const DataBlock &dataBlock);
    void writeMetadata(pugi::xml_node &node);
    void updateImageAttachmentPos(pugi::xml_node &root, size_t offset);
    ByteArray _xisfHeader;
    ByteArray _attachmentsData;
    std::vector<Image> _images;
};

void XISFWriterPrivate::save(const String &name)
{
    std::ofstream fw(name.c_str(), std::ios_base::out | std::ios_base::binary);

    if(fw.fail())
        throw Error("Failed to open file");

    save(fw);
}

void XISFWriterPrivate::save(ByteArray &data)
{
    StreamBuffer buffer;
    std::ostream oss(&buffer);
    save(oss);
    data = buffer.byteArray();
}

void XISFWriterPrivate::save(std::ostream &io)
{
    writeHeader();

    io.write(_xisfHeader.constData(), _xisfHeader.size());

    for(auto &image : _images)
    {
        const char *ptr = image._dataBlock.data.constData();
        size_t size = image._dataBlock.data.size();
        while(size > 0)
        {
            size_t s = std::min(size, GiB);
            io.write(ptr, s);
            ptr += s;
            size -= s;
        }
    }
}

void XISFWriterPrivate::writeImage(const Image &image)
{
    _images.push_back(image);
    _images.back()._dataBlock.attachmentPos = 1;
    _images.back()._dataBlock.compress(image.sampleFormatSize(image.sampleFormat()));
}

void XISFWriterPrivate::writeHeader()
{
    const char signature[16] = {'X', 'I', 'S', 'F', '0', '1', '0', '0', 0, 0, 0, 0, 0, 0, 0, 0};

    pugi::xml_document doc;
    doc.append_child(pugi::node_comment).set_value("\nExtensible Image Serialization Format - XISF version 1.0\nCreated with libXISF - https://nouspiro.space\n");

    pugi::xml_node root = doc.append_child("xisf");
    root.append_attribute("version").set_value("1.0");
    root.append_attribute("xmlns").set_value("http://www.pixinsight.com/xisf");
    root.append_attribute("xmlns:xsi").set_value("http://www.w3.org/2001/XMLSchema-instance");
    root.append_attribute("xsi:schemaLocation").set_value("http://www.pixinsight.com/xisf http://pixinsight.com/xisf/xisf-1.0.xsd");

    for(Image &image : _images)
    {
        writeImageElement(root, image);
    }

    writeMetadata(root);

    uint32_t size = 0;
    std::string header;
    while(true)
    {
        std::stringstream xml;
        xml.write(signature, sizeof(signature));
        doc.save(xml, "", pugi::format_raw);
        header = xml.str();
        if(size != header.size())
        {
            size = header.size();
            updateImageAttachmentPos(root, size);
        }
        else
        {
            break;
        }
    }

    uint32_t headerSize = header.size() - sizeof(signature);
    header.replace(8, sizeof(uint32_t), (const char*)&headerSize, sizeof(uint32_t));

    _xisfHeader = ByteArray(header.c_str(), header.size());
}

void XISFWriterPrivate::writeImageElement(pugi::xml_node &node, const Image &image)
{
    pugi::xml_node image_node = node.append_child("Image");
    std::string geometry = std::to_string(image._width) + ":" + std::to_string(image._height) + ":" + std::to_string(image._channelCount);
    image_node.append_attribute("geometry").set_value(geometry.c_str());
    image_node.append_attribute("sampleFormat").set_value(Image::sampleFormatString(image._sampleFormat).c_str());
    image_node.append_attribute("colorSpace").set_value(Image::colorSpaceString(image._colorSpace).c_str());
    image_node.append_attribute("imageType").set_value(Image::imageTypeString(image._imageType).c_str());
    image_node.append_attribute("pixelStorage").set_value(Image::pixelStorageString(image._pixelStorage).c_str());
    if((image._sampleFormat == Image::Float32 || image._sampleFormat == Image::Float64) ||
            image._bounds.first != 0.0 || image._bounds.second != 1.0)
    {
        std::string bounds = std::to_string(image._bounds.first) + ":" + std::to_string(image._bounds.second);
        image_node.append_attribute("bounds").set_value(bounds.c_str());
    }

    writeDataBlockAttributes(image_node, image._dataBlock);
    for(auto &property : image._properties)
        writePropertyElement(image_node, property);

    for(auto &fitsKeyword : image._fitsKeywords)
        writeFITSKeyword(image_node, fitsKeyword);

    if(image._cfa.width && image._cfa.height)
    {
        pugi::xml_node cfa_node = image_node.append_child("ColorFilterArray");
        cfa_node.append_attribute("pattern").set_value(image._cfa.pattern.c_str());
        cfa_node.append_attribute("width").set_value(image._cfa.width);
        cfa_node.append_attribute("height").set_value(image._cfa.height);
    }

    if(image._iccProfile.size())
    {
        ByteArray base64 = image._iccProfile;
        base64.encodeBase64();
        base64.append('\0');
        pugi::xml_node icc_node = image_node.append_child("ICCProfile");
        icc_node.append_attribute("location").set_value("inline:base64");
        icc_node.append_child(pugi::node_pcdata).set_value(base64.data());
    }
}

void XISFWriterPrivate::writeDataBlockAttributes(pugi::xml_node &image_node, const DataBlock &dataBlock)
{
    if(dataBlock.embedded)
    {
        image_node.append_attribute("location").set_value("embedded");
    }
    else if(dataBlock.attachmentPos == 0)
    {
        image_node.append_attribute("location").set_value("inline:base64");
    }
    else
    {
        std::string attachment = "attachment:";
        if(dataBlock.attachmentPos == 0) attachment += "99999";
        else attachment += std::to_string(dataBlock.attachmentPos);
        attachment += ":" + std::to_string(dataBlock.data.size());
        image_node.append_attribute("location").set_value(attachment.c_str());
    }

    std::string codec;

    if(dataBlock.codec == DataBlock::Zlib)
        codec = "zlib";
    else if(dataBlock.codec == DataBlock::LZ4)
        codec = "lz4";
    else if(dataBlock.codec == DataBlock::LZ4HC)
        codec = "lz4hc";
    else if(dataBlock.codec == DataBlock::ZSTD)
#ifdef HAVE_ZSTD
        codec = "zstd";
#else
        throw Error("ZSTD support not compiled");
#endif

    if(dataBlock.byteShuffling > 1)
        codec += "+sh";

    if(!codec.empty())
    {
        codec += ":" + std::to_string(dataBlock.uncompressedSize);
        if(dataBlock.byteShuffling > 1)
            codec += ":" + std::to_string(dataBlock.byteShuffling);

        image_node.append_attribute("compression").set_value(codec.c_str());
    }

    if(!dataBlock.subblocks.empty())
    {
        std::string subblocks;
        for(auto i = dataBlock.subblocks.begin(); i != dataBlock.subblocks.end(); i++)
        {
            if(i != dataBlock.subblocks.begin())
                subblocks += ":";

            subblocks += std::to_string(i->first) + "," + std::to_string(i->second);
        }
        image_node.append_attribute("subblocks").set_value(subblocks.c_str());
    }
}

void XISFWriterPrivate::writePropertyElement(pugi::xml_node &node, const Property &property)
{
    pugi::xml_node property_node = node.append_child("Property");
    property_node.append_attribute("id").set_value(property.id.c_str());

    serializeVariant(property_node, property.value);

    if(!property.comment.empty())
        property_node.append_attribute("comment").set_value(property.comment.c_str());
}

void XISFWriterPrivate::writeFITSKeyword(pugi::xml_node &node, const FITSKeyword &keyword)
{
    pugi::xml_node fits_node = node.append_child("FITSKeyword");
    fits_node.append_attribute("name").set_value(keyword.name.c_str());
    fits_node.append_attribute("value").set_value(keyword.value.c_str());
    fits_node.append_attribute("comment").set_value(keyword.comment.c_str());
}

void XISFWriterPrivate::writeMetadata(pugi::xml_node &node)
{
    pugi::xml_node metadata = node.append_child("Metadata");
    std::time_t t = std::time(nullptr);
    std::tm tm = *std::gmtime(&t);
    writePropertyElement(metadata, Property("XISF:CreationTime", tm));
    writePropertyElement(metadata, Property("XISF:CreatorApplication", "LibXISF"));
}

void XISFWriterPrivate::updateImageAttachmentPos(pugi::xml_node &root, size_t offset)
{
    pugi::xpath_node_set imageNodes = root.select_nodes("//Image");
    int i = 0;
    for(auto &image : _images)
    {
        pugi::xml_node node = imageNodes[i++].node();
        std::string location = "attachment:" + std::to_string(offset) + ":" + std::to_string(image._dataBlock.data.size());
        offset += image._dataBlock.data.size();
        node.attribute("location").set_value(location.c_str());
    }
}

XISFReader::XISFReader()
{
    p = new XISFReaderPrivate;
}

XISFReader::~XISFReader()
{
    delete p;
}

void XISFReader::open(const String &name)
{
    p->open(name);
}

void XISFReader::open(const ByteArray &data)
{
    p->open(data);
}

void XISFReader::open(std::istream *io)
{
    p->open(io);
}

void XISFReader::close()
{
    p->close();
}

int XISFReader::imagesCount() const
{
    return p->imagesCount();
}

const Image &XISFReader::getImage(uint32_t n, bool readPixels)
{
    return p->getImage(n, readPixels);
}

const Image &XISFReader::getThumbnail()
{
    return p->getThumbnail();
}

XISFWriter::XISFWriter()
{
    p = new XISFWriterPrivate;
}

XISFWriter::~XISFWriter()
{
    delete p;
}

void XISFWriter::save(const String &name)
{
    p->save(name);
}

void XISFWriter::save(ByteArray &data)
{
    p->save(data);
}

void XISFWriter::save(std::ostream &io)
{
    p->save(io);
}

void XISFWriter::writeImage(const Image &image)
{
    p->writeImage(image);
}

class XISFModifyPrivate
{
public:
    void open(const String &name);
    void open(const ByteArray &data);
    /** Open image from istream. This method takes ownership of *io pointer */
    void open(std::istream *io);
    /** Close opended file release all data. */
    void close();

    void save(const String &name);
    void save(ByteArray &data);
    void save(std::ostream &io);

    void addFITSKeyword(uint32_t image, const FITSKeyword &keyword);
    void updateFITSKeyword(uint32_t image, const FITSKeyword &keyword, bool add);
    void removeFITSKeyword(uint32_t image, const String &name);
    void updateProperty(uint32_t image, const Property &property);
private:
    void readXISFHeader();
    void parseAttachmentPos(pugi::xml_node &root);
    void updateAttachmentPos(pugi::xml_node &root, size_t offset);

    std::unique_ptr<std::istream> _io;
    std::unique_ptr<StreamBuffer> _buffer;

    pugi::xml_document _doc;
    pugi::xml_node _root;
    std::map<int, std::pair<uint64_t, uint64_t>> _attachmentPos;// pair contain position and size
};


void XISFModifyPrivate::open(const String &name)
{
    close();
    _io = std::make_unique<std::ifstream>(name.c_str(), std::ios_base::in | std::ios_base::binary);
    readXISFHeader();
}

void XISFModifyPrivate::open(const ByteArray &data)
{
    close();
    _buffer = std::make_unique<StreamBuffer>(data);
    _io = std::make_unique<std::istream>(_buffer.get());
    readXISFHeader();
}

void XISFModifyPrivate::open(std::istream *io)
{
    close();
    _io.reset(io);
    readXISFHeader();
}

void XISFModifyPrivate::close()
{
    _io.reset();
    _buffer.reset();
    _root = pugi::xml_node();
    _doc.reset();
}

void XISFModifyPrivate::save(const String &name)
{
    std::ofstream fw(name.c_str(), std::ios_base::out | std::ios_base::binary);

    if(fw.fail())
        throw Error("Failed to open file");

    save(fw);
}

void XISFModifyPrivate::save(ByteArray &data)
{
    StreamBuffer buffer;
    std::ostream oss(&buffer);
    save(oss);
    data = buffer.byteArray();
}

void XISFModifyPrivate::save(std::ostream &io)
{
    if(!_io || !_root)
        throw Error("No input file opened");

    const char signature[16] = {'X', 'I', 'S', 'F', '0', '1', '0', '0', 0, 0, 0, 0, 0, 0, 0, 0};

    pugi::xml_document doc;
    doc.append_child(pugi::node_comment).set_value("\nExtensible Image Serialization Format - XISF version 1.0\nCreated with libXISF - https://nouspiro.space\n");
    pugi::xml_node root_copy = doc.append_copy(_root);

    parseAttachmentPos(_root);

    uint32_t size = 0;
    std::string header;
    while(true)
    {
        std::stringstream xml;
        xml.write(signature, sizeof(signature));
        doc.save(xml, "", pugi::format_raw);
        header = xml.str();
        if(size != header.size())
        {
            size = header.size();
            updateAttachmentPos(root_copy, size);
        }
        else
        {
            break;
        }
    }

    uint32_t headerSize = header.size() - sizeof(signature);
    header.replace(8, sizeof(uint32_t), (const char*)&headerSize, sizeof(uint32_t));

    io.write(header.c_str(), header.size());
    const uint64_t BLOCK_SIZE = 1024*1024*4;
    std::vector<char> data(BLOCK_SIZE);
    for(auto &pos : _attachmentPos)
    {
        uint64_t oldPos = pos.second.first;
        uint64_t size = pos.second.second;

        _io->seekg(oldPos);
        while(size)
        {
            _io->read(&data[0], std::min(size, BLOCK_SIZE));
            io.write(&data[0], std::min(size, BLOCK_SIZE));
            size -= std::min(size, BLOCK_SIZE);
        }
    }
}

void XISFModifyPrivate::addFITSKeyword(uint32_t image, const FITSKeyword &keyword)
{
    if(!_root)
        throw Error("No input file opened");

    pugi::xpath_node_set images = _root.select_nodes("//Image");

    if(image >= images.size())
        throw Error("Out of bounds");

    pugi::xml_node imageNode = images[image].node();
    XISFWriterPrivate::writeFITSKeyword(imageNode, keyword);
}

void XISFModifyPrivate::updateFITSKeyword(uint32_t image, const FITSKeyword &keyword, bool add)
{
    if(!_root)
        throw Error("No input file opened");

    pugi::xpath_node_set images = _root.select_nodes("//Image");

    if(image >= images.size())
        throw Error("Out of bounds");

    pugi::xpath_variable_set variables;
    variables.set("name", keyword.name.c_str());
    pugi::xml_node imageNode = images[image].node();
    pugi::xml_node keywordNode = imageNode.select_node("FITSKeyword[@name=string($name)]", &variables).node();

    if(keywordNode)
    {
        if(keywordNode.attribute("value"))
            keywordNode.attribute("value").set_value(keyword.value.c_str());
        else
            keywordNode.append_attribute("value").set_value(keyword.value.c_str());

        if(keywordNode.attribute("comment"))
            keywordNode.attribute("comment").set_value(keyword.comment.c_str());
        else
            keywordNode.append_attribute("comment").set_value(keyword.comment.c_str());
    }
    else if(add)
    {
        XISFWriterPrivate::writeFITSKeyword(imageNode, keyword);
    }
}

void XISFModifyPrivate::removeFITSKeyword(uint32_t image, const String &name)
{
    if(!_root)
        throw Error("No input file opened");

    pugi::xpath_node_set images = _root.select_nodes("//Image");

    if(image >= images.size())
        throw Error("Out of bounds");

    pugi::xpath_variable_set variables;
    variables.set("name", name.c_str());
    pugi::xml_node imageNode = images[image].node();
    pugi::xml_node keywordNode = imageNode.select_node("FITSKeyword[@name=string($name)]", &variables).node();

    if(keywordNode)
        imageNode.remove_child(keywordNode);
}

void XISFModifyPrivate::updateProperty(uint32_t image, const Property &property)
{
    if(!_root)
        throw Error("No input file opened");

    pugi::xpath_node_set images = _root.select_nodes("//Image");

    if(image >= images.size())
        throw Error("Out of bounds");

    pugi::xpath_variable_set variables;
    variables.set("id", property.id.c_str());
    pugi::xml_node imageNode = images[image].node();
    pugi::xml_node propertyNode = imageNode.select_node("Property[@id=string($id)]", &variables).node();

    if(propertyNode)
        imageNode.remove_child(propertyNode);

    XISFWriterPrivate::writePropertyElement(imageNode, property);
}

void XISFModifyPrivate::readXISFHeader()
{
    char signature[8];
    _io->read(signature, sizeof(signature));
    if(_io->fail())
        throw Error("Failed to read from file");

    if(memcmp(signature, "XISF0100", sizeof(signature)) != 0)
        throw Error("Not valid XISF 1.0 file");

    uint32_t headerLen[2] = {0};
    _io->read((char*)&headerLen, sizeof(headerLen));

    ByteArray xisfHeader(headerLen[0]);
    _io->read(xisfHeader.data(), headerLen[0]);

    _doc.load_buffer(xisfHeader.data(), xisfHeader.size());

    _root = _doc.child("xisf");

    parseAttachmentPos(_root);

    if(!_root || _root.attribute("version").as_string() != std::string("1.0"))
        throw Error("Unknown root XML element");
}

void XISFModifyPrivate::parseAttachmentPos(pugi::xml_node &root)
{
    _attachmentPos.clear();
    pugi::xpath_node_set locationAttributes = root.select_nodes("//@location");
    int i = 0;
    for(auto &attr : locationAttributes)
    {
        std::string locationStr = attr.attribute().as_string();
        std::vector<std::string> location = splitString(locationStr, ':');
        if(location.size() >= 3 && location[0] == "attachment")
        {
            uint64_t attachmentPos = std::stoull(location[1]);
            uint64_t attachmentSize = std::stoull(location[2]);
            _attachmentPos[i] = {attachmentPos, attachmentSize};
        }
        i++;
    }
}

void XISFModifyPrivate::updateAttachmentPos(pugi::xml_node &root, size_t offset)
{
    pugi::xpath_node_set locationAttributes = root.select_nodes("//@location");
    for(auto &pos : _attachmentPos)
    {
        pugi::xml_attribute attr = locationAttributes[pos.first].attribute();
        uint64_t attachmentSize = pos.second.second;
        std::string locationStr = "attachment:" + std::to_string(offset) + ":" + std::to_string(attachmentSize);
        offset += attachmentSize;
        attr.set_value(locationStr.c_str());
    }
}

XISFModify::XISFModify()
{
    p = new XISFModifyPrivate();
}

XISFModify::~XISFModify()
{
    delete p;
}

void XISFModify::open(const String &name)
{
    p->open(name);
}

void XISFModify::open(const ByteArray &data)
{
    p->open(data);
}

void XISFModify::open(std::istream *io)
{
    p->open(io);
}

void XISFModify::close()
{
    p->close();
}

void XISFModify::save(const String &name)
{
    p->save(name);
}

void XISFModify::save(ByteArray &data)
{
    p->save(data);
}

void XISFModify::save(std::ostream &io)
{
    p->save(io);
}

void XISFModify::addFITSKeyword(uint32_t image, const FITSKeyword &keyword)
{
    p->addFITSKeyword(image, keyword);
}

void XISFModify::updateFITSKeyword(uint32_t image, const FITSKeyword &keyword, bool add)
{
    p->updateFITSKeyword(image, keyword, add);
}

void XISFModify::removeFITSKeyword(uint32_t image, const String &name)
{
    p->removeFITSKeyword(image, name);
}

void XISFModify::updateProperty(uint32_t image, const Property &property)
{
    p->updateProperty(image, property);
}

#define STRING_ENUM(map, map2, c, e) { map.insert({#e, c::e}); map2.insert({c::e, #e}); }

struct Init
{
    Init()
    {
        STRING_ENUM(imageTypeToEnum, imageTypeToString, Image, Bias);
        STRING_ENUM(imageTypeToEnum, imageTypeToString, Image, Dark);
        STRING_ENUM(imageTypeToEnum, imageTypeToString, Image, Flat);
        STRING_ENUM(imageTypeToEnum, imageTypeToString, Image, Light);
        STRING_ENUM(imageTypeToEnum, imageTypeToString, Image, MasterBias);
        STRING_ENUM(imageTypeToEnum, imageTypeToString, Image, MasterDark);
        STRING_ENUM(imageTypeToEnum, imageTypeToString, Image, MasterFlat);
        STRING_ENUM(imageTypeToEnum, imageTypeToString, Image, DefectMap);
        STRING_ENUM(imageTypeToEnum, imageTypeToString, Image, RejectionMapHigh);
        STRING_ENUM(imageTypeToEnum, imageTypeToString, Image, RejectionMapLow);
        STRING_ENUM(imageTypeToEnum, imageTypeToString, Image, BinaryRejectionMapHigh);
        STRING_ENUM(imageTypeToEnum, imageTypeToString, Image, BinaryRejectionMapLow);
        STRING_ENUM(imageTypeToEnum, imageTypeToString, Image, SlopeMap);
        STRING_ENUM(imageTypeToEnum, imageTypeToString, Image, WeightMap);

        STRING_ENUM(sampleFormatToEnum, sampleFormatToString, Image, UInt8);
        STRING_ENUM(sampleFormatToEnum, sampleFormatToString, Image, UInt16);
        STRING_ENUM(sampleFormatToEnum, sampleFormatToString, Image, UInt32);
        STRING_ENUM(sampleFormatToEnum, sampleFormatToString, Image, UInt64);
        STRING_ENUM(sampleFormatToEnum, sampleFormatToString, Image, Float32);
        STRING_ENUM(sampleFormatToEnum, sampleFormatToString, Image, Float64);
        STRING_ENUM(sampleFormatToEnum, sampleFormatToString, Image, Complex32);
        STRING_ENUM(sampleFormatToEnum, sampleFormatToString, Image, Complex64);

        STRING_ENUM(colorSpaceToEnum, colorSpaceToString, Image, Gray);
        STRING_ENUM(colorSpaceToEnum, colorSpaceToString, Image, RGB);
        STRING_ENUM(colorSpaceToEnum, colorSpaceToString, Image, CIELab);

        const char *compression_env = std::getenv("LIBXISF_COMPRESSION");
        if(compression_env)
        {
            std::string compression = compression_env;
            if(compression.find("zlib") == 0)
                compressionCodecOverride = DataBlock::Zlib;
            else if(compression.find("lz4hc") == 0)
                compressionCodecOverride = DataBlock::LZ4HC;
            else if(compression.find("lz4") == 0)
                compressionCodecOverride = DataBlock::LZ4;
#ifdef HAVE_ZSTD
            else if(compression.find("zstd") == 0)
                compressionCodecOverride = DataBlock::ZSTD;
#endif

            if(compression.find("+sh") != std::string::npos)
                byteShuffleOverride = true;

            int index = compression.find_last_of(":");
            if(index > 0)
            {
                try { compressionLevelOverride = std::stoi(compression.substr(index + 1)); }
                catch(...) { /* do nothing */ }
            }
        }
    }
};

static Init init;

}
