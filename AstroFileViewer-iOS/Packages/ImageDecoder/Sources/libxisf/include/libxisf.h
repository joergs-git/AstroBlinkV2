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

#ifndef LIBXISF_H
#define LIBXISF_H

#include "libXISF_global.h"
#include <memory>
#include <map>
#include <variant>
#include <fstream>
#include <cstring>
#include <vector>
#include <cstdint>
#include <memory>
#include <ctime>

namespace LibXISF
{

class XISFReaderPrivate;
class XISFWriterPrivate;
class XISFModifyPrivate;

class LIBXISF_EXPORT ByteArray
{
    using PtrType = std::vector<char>;
    using Ptr = std::shared_ptr<PtrType>;
    Ptr _data;
    void makeUnique();
public:
    ByteArray() : ByteArray((size_t)0) {}
    explicit ByteArray(size_t size);
    explicit ByteArray(const char *ptr);
    ByteArray(const char *ptr, size_t size)
    {
        _data = std::make_shared<std::vector<char>>();
        _data->resize(size);
        std::memcpy(data(), ptr, size);
    }
    ByteArray(const ByteArray &d);
    char& operator[](size_t i);
    const char& operator[](size_t i) const;
    char* data() { return &_data->at(0); }
    const char* data() const { return &_data->at(0); }
    const char* constData() const { return &_data->at(0); }
    size_t size() const;
    void resize(size_t newsize);
    void append(char c);
    void decodeBase64();
    void encodeBase64();
    void encodeHex();
    void decodeHex();
};

struct Complex32
{
    float real;
    float imag;
};

struct Complex64
{
    double real;
    double imag;
};

template<typename T>
class Matrix
{
    int _rows = 0;
    int _cols = 0;
    std::vector<T> _elem;
public:
    using value_type = T;

    Matrix() = default;
    Matrix(int rows, int cols) : _rows(rows), _cols(cols), _elem(rows * cols) {}
    void resize(int rows, int cols) { _rows = rows; _cols = cols; _elem.resize(rows * cols); }
    T& operator()(int row, int col) { return _elem[row * _cols + col]; }
    const T& operator()(int row, int col) const { return _elem[row * _cols + col]; }
    int rows() const { return _rows; }
    int cols() const { return _cols; }
};

typedef bool Boolean;
typedef int8_t Int8;
typedef uint8_t UInt8;
typedef int16_t Int16;
typedef uint16_t UInt16;
typedef int32_t Int32;
typedef uint32_t UInt32;
typedef int64_t Int64;
typedef uint64_t UInt64;
typedef float Float32;
typedef double Float64;
typedef std::string String;
typedef std::tm TimePoint;
typedef std::vector<int8_t> I8Vector;
typedef std::vector<uint8_t> UI8Vector;
typedef std::vector<int16_t> I16Vector;
typedef std::vector<uint16_t> UI16Vector;
typedef std::vector<int32_t> I32Vector;
typedef std::vector<uint32_t> UI32Vector;
typedef std::vector<int64_t> I64Vector;
typedef std::vector<uint64_t> UI64Vector;
typedef std::vector<float> F32Vector;
typedef std::vector<double> F64Vector;
typedef std::vector<Complex32> C32Vector;
typedef std::vector<Complex64> C64Vector;
typedef Matrix<Int8> I8Matrix;
typedef Matrix<UInt8> UI8Matrix;
typedef Matrix<Int16> I16Matrix;
typedef Matrix<UInt16> UI16Matrix;
typedef Matrix<Int32> I32Matrix;
typedef Matrix<UInt32> UI32Matrix;
typedef Matrix<Int64> I64Matrix;
typedef Matrix<UInt64> UI64Matrix;
typedef Matrix<float> F32Matrix;
typedef Matrix<double> F64Matrix;
typedef Matrix<Complex32> C32Matrix;
typedef Matrix<Complex64> C64Matrix;

class LIBXISF_EXPORT Variant
{
    using StdVariant = std::variant<std::monostate, Boolean, Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64, Float32, Float64,
        Complex32, Complex64, String, TimePoint,
        I8Vector, UI8Vector, I16Vector, UI16Vector, I32Vector, UI32Vector, I64Vector, UI64Vector, F32Vector, F64Vector, C32Vector, C64Vector,
        I8Matrix, UI8Matrix, I16Matrix, UI16Matrix, I32Matrix, UI32Matrix, I64Matrix, UI64Matrix, F32Matrix, F64Matrix, C32Matrix, C64Matrix>;
    StdVariant _value;
public:
    enum class Type
    {
        Monostate, Boolean, Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64, Float32, Float64,
        Complex32, Complex64, String, TimePoint,
        I8Vector, UI8Vector, I16Vector, UI16Vector, I32Vector, UI32Vector, I64Vector, UI64Vector, F32Vector, F64Vector, C32Vector, C64Vector,
        I8Matrix, UI8Matrix, I16Matrix, UI16Matrix, I32Matrix, UI32Matrix, I64Matrix, UI64Matrix, F32Matrix, F64Matrix, C32Matrix, C64Matrix
    };

    Variant() = default;
    template<typename T>
    Variant(const T &t) : _value(t) {}
    Type type() const;
    const char *typeName() const;
    template<typename T>
    T& value() { return std::get<T>(_value); }
    template<typename T>
    const T& value() const { return std::get<T>(_value); }
    template<typename T>
    void setValue(const T& val) { _value = val; }
    String toString() const;
};

struct LIBXISF_EXPORT DataBlock
{
    enum CompressionCodec
    {
        None,
        Zlib,
        LZ4,
        LZ4HC,
        ZSTD
    };
    bool embedded = false;
    uint32_t byteShuffling = 0;
    uint64_t attachmentPos = 0;
    uint64_t attachmentSize = 0;
    uint64_t uncompressedSize = 0;
    std::vector<std::pair<uint64_t, uint64_t>> subblocks;
    CompressionCodec codec = None;
    int compressLevel = -1;
    ByteArray data;
    void decompress(const ByteArray &input, const std::string &encoding = "");
    void compress(int sampleFormatSize);
    /// ZSTD compression can be disabled at compile time
    static bool CompressionCodecSupported(CompressionCodec codec);
};

struct LIBXISF_EXPORT Property
{
    String id;
    Variant value;
    String comment;

    Property() = default;
    Property(const Property &) = default;
    Property(const String &_id, const char *_value);
    template<typename T>
    Property(const String &_id, const T& _value) :
        id(_id),
        value(_value){}
};

struct LIBXISF_EXPORT FITSKeyword
{
    String name;
    String value;
    String comment;
};

/**
Describe color filter array. Each letter in pattern describe color of element.
0 - A nonexistent or undefined CFA element
R - Red
G - Green
B - Blue
W - White or panchromatic
C - Cyan
M - Magenta
Y - Yellow
*/
struct LIBXISF_EXPORT ColorFilterArray
{
    int width = 0;
    int height = 0;
    String pattern;
};

typedef std::pair<double, double> Bounds;

class LIBXISF_EXPORT Image
{
public:
    enum Type
    {
        Bias,
        Dark,
        Flat,
        Light,
        MasterBias,
        MasterDark,
        MasterFlat,
        DefectMap,
        RejectionMapHigh,
        RejectionMapLow,
        BinaryRejectionMapHigh,
        BinaryRejectionMapLow,
        SlopeMap,
        WeightMap
    };
    /**
    Planar - each channel samples are stored separately for example RGB image will be stored RRRRGGGGBBBB
    Normal - channel values for each pixel are stored inteleaved RGBRGBRGBRGB */
    enum PixelStorage
    {
        Planar,
        Normal
    };
    enum SampleFormat
    {
        UInt8,
        UInt16,
        UInt32,
        UInt64,
        Float32,
        Float64,
        Complex32,
        Complex64
    };
    enum ColorSpace
    {
        Gray,
        RGB,
        CIELab
    };
    Image() = default;
    Image(uint64_t width, uint64_t height, uint64_t channelCount = 1, SampleFormat sampleFormat = UInt16, ColorSpace colorSpace = Gray, PixelStorage pixelStorate = Planar);

    uint64_t width() const;
    uint64_t height() const;
    uint64_t channelCount() const;
    void setGeometry(uint64_t width, uint64_t height, uint64_t channelCount);
    const Bounds &bounds() const;
    void setBounds(const Bounds &newBounds);
    Type imageType() const;
    void setImageType(Type newImageType);
    PixelStorage pixelStorage() const;
    void setPixelStorage(PixelStorage newPixelStorage);
    SampleFormat sampleFormat() const;
    void setSampleFormat(SampleFormat newSampleFormat);
    ColorSpace colorSpace() const;
    void setColorSpace(ColorSpace newColorSpace);
    const ColorFilterArray colorFilterArray() const;
    void setColorFilterArray(const ColorFilterArray cfa);
    const std::vector<Property> &imageProperties() const;
    void addProperty(const Property &property);
    void updateProperty(const Property &property);
    const std::vector<FITSKeyword> fitsKeywords() const;
    void addFITSKeyword(const FITSKeyword &keyword);
    /** Add image property while doing automatic conversion of FITS name to XISF property
     *  For example OBSERVER => Observer:Name, SITELAT => Observation:Location:Latitude
    */
    bool addFITSKeywordAsProperty(const String &name, const String &value);
    const ByteArray& iccProfile() const;
    void setIccProfile(const ByteArray &iccProfile);

    void* imageData();
    const void* imageData() const;
    template<typename T>
    T* imageData(){ return static_cast<T*>(imageData()); }
    template<typename T>
    const T* imageData() const { return static_cast<const T*>(imageData()); }
    size_t imageDataSize() const;
    DataBlock::CompressionCodec compression() const;
    /** Set compression type and level.
     *  @param compression define which compression algorithm to use.
     *  @param level number between 0 and 100. Zero means lowest compression and maximum speed. Hundred means maximum compression speed.
     *  -1 means default compression level defined by compression library.
     */
    void setCompression(DataBlock::CompressionCodec compression, int level = -1);
    bool byteShuffling() const;
    void setByteshuffling(bool enable);

    /** Convert between Planar and Normal storage format s*/
    void convertPixelStorageTo(PixelStorage storage);

    static Type imageTypeEnum(const String &type);
    static String imageTypeString(Type type);
    static PixelStorage pixelStorageEnum(const String &storage);
    static String pixelStorageString(PixelStorage storage);
    static SampleFormat sampleFormatEnum(const String &format);
    template<typename T>
    constexpr static SampleFormat sampleFormatEnum();
    static String sampleFormatString(SampleFormat format);
    static ColorSpace colorSpaceEnum(const String &colorSpace);
    static String colorSpaceString(ColorSpace colorSpace);
    static size_t sampleFormatSize(SampleFormat sampleFormat);

private:
    uint64_t _width = 0;
    uint64_t _height = 0;
    uint64_t _channelCount = 1;
    Bounds _bounds = {0.0, 1.0};
    Type _imageType = Light;
    PixelStorage _pixelStorage = Planar;
    SampleFormat _sampleFormat = UInt16;
    ColorSpace _colorSpace = Gray;
    DataBlock _dataBlock;
    ByteArray _iccProfile;
    ColorFilterArray _cfa;
    std::vector<Property> _properties;
    std::map<String, uint32_t> _propertiesId;
    std::vector<FITSKeyword> _fitsKeywords;

    friend class XISFReaderPrivate;
    friend class XISFWriterPrivate;
};

class LIBXISF_EXPORT XISFReader
{
public:
    XISFReader();
    virtual ~XISFReader();
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
     *  @param readPixel when false it will not read pixel data from file and imageData()
     *  will return nullptr. Other properties like width, height, format etc will be returned correctly */
    const Image& getImage(uint32_t n, bool readPixels = true);
    /**
     * @brief getThumbnail
     * @return image thumbnail
     */
    const Image& getThumbnail();
private:
    XISFReaderPrivate *p;
};

class LIBXISF_EXPORT XISFWriter
{
public:
    XISFWriter();
    virtual ~XISFWriter();
    void save(const String &name);
    void save(ByteArray &data);
    void save(std::ostream &io);
    void writeImage(const Image &image);
private:
    XISFWriterPrivate *p;
};

class LIBXISF_EXPORT Error : public std::exception
{
    std::string _msg;
public:
    Error() = default;
    explicit Error(const char *msg) : Error(std::string(msg)) {}
    explicit Error(const std::string &msg) : std::exception(), _msg(msg) {}
    const char* what() const noexcept { return _msg.c_str(); }
};

class LIBXISF_EXPORT XISFModify
{
public:
    XISFModify();
    virtual ~XISFModify();
    void open(const String &name);
    void open(const ByteArray &data);
    void open(std::istream *io);
    void close();
    void save(const String &name);
    void save(ByteArray &data);
    void save(std::ostream &io);

    /**
     * @brief addFITSKeyword append new keyword to image
     * @param image index of image to update
     * @param keyword that will be added
     */
    void addFITSKeyword(uint32_t image, const FITSKeyword &keyword);
    /**
     * @brief updateFITSKeyword update keyword with same name
     * @param image index of image to update
     * @param keyword that will be updated
     * @param add if true then it will add new keyword in case that it doesn't exists
     */
    void updateFITSKeyword(uint32_t image, const FITSKeyword &keyword, bool add);
    /**
     * @brief removeFITSKeyword remove keyword with name from image
     * @param image index of image to update
     * @param name of keyword that will be removed
     */
    void removeFITSKeyword(uint32_t image, const String &name);
    /**
     * @brief updateProperty add new or update existing XISF Property
     * @param image index of image to update
     * @param property new value of property
     */
    void updateProperty(uint32_t image, const Property &property);
private:
    XISFModifyPrivate *p;
};

template<typename T>
constexpr Image::SampleFormat Image::sampleFormatEnum()
{
    if(std::is_same<T, LibXISF::UInt8>::value)return Image::UInt8;
    if(std::is_same<T, LibXISF::UInt16>::value)return Image::UInt16;
    if(std::is_same<T, LibXISF::UInt32>::value)return Image::UInt32;
    if(std::is_same<T, LibXISF::UInt64>::value)return Image::UInt64;
    if(std::is_same<T, LibXISF::Float32>::value)return Image::Float32;
    if(std::is_same<T, LibXISF::Float64>::value)return Image::Float64;
    if(std::is_same<T, LibXISF::Complex32>::value)return Image::Complex32;
    if(std::is_same<T, LibXISF::Complex64>::value)return Image::Complex64;
}

}

#endif // LIBXISF_H
