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

#include <charconv>
#include <map>
#include <regex>
#include <iomanip>
#include <sstream>
#include "libxisf.h"
#include <pugixml.hpp>

namespace LibXISF
{

static std::map<std::string, Variant::Type> typeToId = {
    {"Monostate",     Variant::Type::Monostate},
    {"Boolean",       Variant::Type::Boolean},
    {"Int8",          Variant::Type::Int8},
    {"UInt8",         Variant::Type::UInt8},
    {"Int16",         Variant::Type::Int16},
    {"UInt16",        Variant::Type::UInt16},
    {"Int32",         Variant::Type::Int32},
    {"UInt32",        Variant::Type::UInt32},
    {"Int64",         Variant::Type::Int64},
    {"UInt64",        Variant::Type::UInt64},
    {"Float32",       Variant::Type::Float32},
    {"Float64",       Variant::Type::Float64},
    {"Complex32",     Variant::Type::Complex32},
    {"Complex64",     Variant::Type::Complex64},
    {"String",        Variant::Type::String},
    {"TimePoint",     Variant::Type::TimePoint},
    {"I8Vector",      Variant::Type::I8Vector},
    {"UI8Vector",     Variant::Type::UI8Vector},
    {"I16Vector",     Variant::Type::I16Vector},
    {"UI16Vector",    Variant::Type::UI16Vector},
    {"I32Vector",     Variant::Type::I32Vector},
    {"UI32Vector",    Variant::Type::UI32Vector},
    {"I64Vector",     Variant::Type::I64Vector},
    {"UI64Vector",    Variant::Type::UI64Vector},
    {"F32Vector",     Variant::Type::F32Vector},
    {"F64Vector",     Variant::Type::F64Vector},
    {"C32Vector",     Variant::Type::C32Vector},
    {"C64Vector",     Variant::Type::C64Vector},
    {"I8Matrix",      Variant::Type::I8Matrix},
    {"UI8Matrix",     Variant::Type::UI8Matrix},
    {"I16Matrix",     Variant::Type::I16Matrix},
    {"UI16Matrix",    Variant::Type::UI16Matrix},
    {"I32Matrix",     Variant::Type::I32Matrix},
    {"UI32Matrix",    Variant::Type::UI32Matrix},
    {"I64Matrix",     Variant::Type::I64Matrix},
    {"UI64Matrix",    Variant::Type::UI64Matrix},
    {"F32Matrix",     Variant::Type::F32Matrix},
    {"F64Matrix",     Variant::Type::F64Matrix},
    {"C32Matrix",     Variant::Type::C32Matrix},
    {"C64Matrix",     Variant::Type::C64Matrix},
};

static std::map<Variant::Type, const char*> idToType = {
    {Variant::Type::Monostate,     "Monostate"},
    {Variant::Type::Boolean,       "Boolean"},
    {Variant::Type::Int8,          "Int8"},
    {Variant::Type::UInt8,         "UInt8"},
    {Variant::Type::Int16,         "Int16"},
    {Variant::Type::UInt16,        "UInt16"},
    {Variant::Type::Int32,         "Int32"},
    {Variant::Type::UInt32,        "UInt32"},
    {Variant::Type::Int64,         "Int64"},
    {Variant::Type::UInt64,        "UInt64"},
    {Variant::Type::Float32,       "Float32"},
    {Variant::Type::Float64,       "Float64"},
    {Variant::Type::Complex32,     "Complex32"},
    {Variant::Type::Complex64,     "Complex64"},
    {Variant::Type::String,        "String"},
    {Variant::Type::TimePoint,     "TimePoint"},
    {Variant::Type::I8Vector,      "I8Vector"},
    {Variant::Type::UI8Vector,     "UI8Vector"},
    {Variant::Type::I16Vector,     "I16Vector"},
    {Variant::Type::UI16Vector,    "UI16Vector"},
    {Variant::Type::I32Vector,     "I32Vector"},
    {Variant::Type::UI32Vector,    "UI32Vector"},
    {Variant::Type::I64Vector,     "I64Vector"},
    {Variant::Type::UI64Vector,    "UI64Vector"},
    {Variant::Type::F32Vector,     "F32Vector"},
    {Variant::Type::F64Vector,     "F64Vector"},
    {Variant::Type::C32Vector,     "C32Vector"},
    {Variant::Type::C64Vector,     "C64Vector"},
    {Variant::Type::I8Matrix,      "I8Matrix"},
    {Variant::Type::UI8Matrix,     "UI8Matrix"},
    {Variant::Type::I16Matrix,     "I16Matrix"},
    {Variant::Type::UI16Matrix,    "UI16Matrix"},
    {Variant::Type::I32Matrix,     "I32Matrix"},
    {Variant::Type::UI32Matrix,    "UI32Matrix"},
    {Variant::Type::I64Matrix,     "I64Matrix"},
    {Variant::Type::UI64Matrix,    "UI64Matrix"},
    {Variant::Type::F32Matrix,     "F32Matrix"},
    {Variant::Type::F64Matrix,     "F64Matrix"},
};

template<typename T>
T fromChars(const char *beg, const char *end)
{
    T val;
    std::from_chars(beg, end, val);
    return val;
}

template<typename T>
T fromCharsComplex(const char *beg, const char *end)
{
    T val = {0, 0};
    std::cmatch match;
    std::regex regex("\\(([^,]+),([^)]+)\\)");
    if(std::regex_match(beg, end, match, regex))
    {
        val.real = std::stod(std::string(match[1].first, match[1].second));
        val.imag = std::stod(std::string(match[1].first, match[1].second));
    }
    return val;
}

template<typename T>
void fromCharsVector(Variant &v, size_t len, const ByteArray &data)
{
    v = T();
    v.value<T>().resize(len);
    size_t size = len * sizeof(typename T::value_type);
    std::memcpy(&v.value<T>()[0], data.data(), size);
}

template<typename T>
void fromCharsMatrix(Variant &v, size_t rows, size_t cols, const ByteArray &data)
{
    v = T(rows, cols);
    size_t size = rows * cols * sizeof(typename T::value_type);
    std::memcpy(&v.value<T>()(0, 0), data.data(), size);
}

template<typename T>
void toChars(const Variant &v, char *beg, char *end)
{
    std::to_chars(beg, end, v.value<T>());
}

template<typename T>
void toCharsComplex(const Variant &v, std::string &str)
{
    T complex = v.value<T>();
    std::stringstream ss;
    ss.imbue(std::locale("C"));
    ss << "(" << complex.real << "," << complex.imag << ")";
    str = ss.str();
}


template<typename T>
void toCharsVector(const Variant &v, size_t &len, ByteArray &data)
{
    len = v.value<T>().size();
    size_t size = len * sizeof(typename T::value_type);
    data.resize(size);
    std::memcpy(data.data(), &v.value<T>()[0], size);
    data.encodeBase64();
    data.append('\0');
}

template<typename T>
void toCharsMatrix(const Variant &v, size_t &rows, size_t &cols, ByteArray &data)
{
    rows = v.value<T>().rows();
    cols = v.value<T>().cols();
    size_t size = rows * cols * sizeof(typename T::value_type);
    data.resize(size);
    std::memcpy(data.data(), &v.value<T>()(0, 0), size);
    data.encodeBase64();
    data.append('\0');
}

void deserializeVariant(const pugi::xml_node &node, Variant &variant, const ByteArray &data)
{
    std::string type = node.attribute("type").as_string();
    Variant::Type typeId = typeToId[type];

    if(typeId == Variant::Type::String)
    {
        if(!node.attribute("location"))
            variant.setValue(node.text().as_string());
        else
            variant.setValue(String(data.constData(), data.size()));
    }
    else if(node.attribute("value"))
    {
        auto attr = node.attribute("value").value();
        switch(typeId)
        {
        case Variant::Type::Int8: variant.setValue(fromChars<Int8>(attr, attr + strlen(attr))); break;
        case Variant::Type::UInt8: variant.setValue(fromChars<UInt8>(attr, attr + strlen(attr))); break;
        case Variant::Type::Int16: variant.setValue(fromChars<Int16>(attr, attr + strlen(attr))); break;
        case Variant::Type::UInt16: variant.setValue(fromChars<UInt16>(attr, attr + strlen(attr))); break;
        case Variant::Type::Int32: variant.setValue(fromChars<Int32>(attr, attr + strlen(attr))); break;
        case Variant::Type::UInt32: variant.setValue(fromChars<UInt32>(attr, attr + strlen(attr))); break;
        case Variant::Type::Int64: variant.setValue(fromChars<Int64>(attr, attr + strlen(attr))); break;
        case Variant::Type::UInt64: variant.setValue(fromChars<UInt64>(attr, attr + strlen(attr))); break;
        case Variant::Type::Float32: variant.setValue(node.attribute("value").as_float()); break;
        case Variant::Type::Float64: variant.setValue(node.attribute("value").as_double()); break;
        case Variant::Type::Complex32: variant.setValue(fromCharsComplex<Complex32>(attr, attr + strlen(attr))); break;
        case Variant::Type::Complex64: variant.setValue(fromCharsComplex<Complex64>(attr, attr + strlen(attr))); break;
        case Variant::Type::TimePoint:
        {
            std::istringstream ss(node.attribute("value").value());
            std::tm tm = {};
            ss >> std::get_time(&tm, "%Y-%m-%dT%H:%M:%SZ");
            variant = tm;
            break;
        }
        case Variant::Type::Boolean:
            variant = node.attribute("value").as_bool();
            break;
        default: break;
        }
    }
    else if(typeId >= Variant::Type::I8Vector && typeId <= Variant::Type::C64Vector)
    {
        size_t len = node.attribute("length").as_ullong();
        switch(typeId)
        {
        case Variant::Type::I8Vector: fromCharsVector<I8Vector>(variant, len, data); break;
        case Variant::Type::UI8Vector: fromCharsVector<UI8Vector>(variant, len, data); break;
        case Variant::Type::I16Vector: fromCharsVector<I16Vector>(variant, len, data); break;
        case Variant::Type::UI16Vector: fromCharsVector<UI16Vector>(variant, len, data); break;
        case Variant::Type::I32Vector: fromCharsVector<I32Vector>(variant, len, data); break;
        case Variant::Type::UI32Vector: fromCharsVector<UI32Vector>(variant, len, data); break;
        case Variant::Type::I64Vector: fromCharsVector<I64Vector>(variant, len, data); break;
        case Variant::Type::UI64Vector: fromCharsVector<UI64Vector>(variant, len, data); break;
        case Variant::Type::F32Vector: fromCharsVector<F32Vector>(variant, len, data); break;
        case Variant::Type::F64Vector: fromCharsVector<F64Vector>(variant, len, data); break;
        case Variant::Type::C32Vector: fromCharsVector<C32Vector>(variant, len, data); break;
        case Variant::Type::C64Vector: fromCharsVector<C64Vector>(variant, len, data); break;
        default: break;
        }
    }
    else if(typeId >= Variant::Type::I8Matrix && typeId <= Variant::Type::C64Matrix)
    {
        size_t rows = node.attribute("rows").as_ullong();
        size_t cols = node.attribute("columns").as_ullong();
        switch(typeId)
        {
        case Variant::Type::I8Matrix: fromCharsMatrix<I8Matrix>(variant, rows, cols, data); break;
        case Variant::Type::UI8Matrix: fromCharsMatrix<UI8Matrix>(variant, rows, cols, data); break;
        case Variant::Type::I16Matrix: fromCharsMatrix<I16Matrix>(variant, rows, cols, data); break;
        case Variant::Type::UI16Matrix: fromCharsMatrix<UI16Matrix>(variant, rows, cols, data); break;
        case Variant::Type::I32Matrix: fromCharsMatrix<I32Matrix>(variant, rows, cols, data); break;
        case Variant::Type::UI32Matrix: fromCharsMatrix<UI32Matrix>(variant, rows, cols, data); break;
        case Variant::Type::I64Matrix: fromCharsMatrix<I64Matrix>(variant, rows, cols, data); break;
        case Variant::Type::UI64Matrix: fromCharsMatrix<UI64Matrix>(variant, rows, cols, data); break;
        case Variant::Type::F32Matrix: fromCharsMatrix<F32Matrix>(variant, rows, cols, data); break;
        case Variant::Type::F64Matrix: fromCharsMatrix<F64Matrix>(variant, rows, cols, data); break;
        case Variant::Type::C32Matrix: fromCharsMatrix<C32Matrix>(variant, rows, cols, data); break;
        case Variant::Type::C64Matrix: fromCharsMatrix<C64Matrix>(variant, rows, cols, data); break;
        default: break;
        }
    }
}

void serializeVariant(pugi::xml_node &node, const Variant &variant)
{
    char str[32] = {0};
    char *end = str + sizeof(str);

    node.append_attribute("type").set_value(variant.typeName());

    if(variant.type() == Variant::Type::String)
    {
        node.append_child(pugi::node_pcdata).set_value(variant.value<String>().c_str());
    }
    else if(variant.type() == Variant::Type::Boolean)
    {
        node.append_attribute("value").set_value(variant.value<Boolean>() ? 1 : 0);
    }
    else if(variant.type() >= Variant::Type::Int8 && variant.type() <= Variant::Type::UInt64)
    {
        switch(variant.type())
        {
        case Variant::Type::Int8: toChars<Int8>(variant, str, end); break;
        case Variant::Type::UInt8: toChars<UInt8>(variant, str, end); break;
        case Variant::Type::Int16: toChars<Int16>(variant, str, end); break;
        case Variant::Type::UInt16: toChars<UInt16>(variant, str, end); break;
        case Variant::Type::Int32: toChars<Int32>(variant, str, end); break;
        case Variant::Type::UInt32: toChars<UInt32>(variant, str, end); break;
        case Variant::Type::Int64: toChars<Int64>(variant, str, end); break;
        case Variant::Type::UInt64: toChars<UInt64>(variant, str, end); break;
        default: break;
        }
        node.append_attribute("value").set_value(str);
    }
    else if(variant.type() == Variant::Type::Float32)
        node.append_attribute("value").set_value(variant.value<Float32>());
    else if(variant.type() == Variant::Type::Float64)
        node.append_attribute("value").set_value(variant.value<Float64>());
    else if(variant.type() == Variant::Type::Complex32 || variant.type() == Variant::Type::Complex64)
    {
        std::string str;
        if(variant.type() == Variant::Type::Complex32)
            toCharsComplex<Complex32>(variant, str);
        else
            toCharsComplex<Complex64>(variant, str);
        node.append_attribute("value").set_value(str.c_str());
    }
    else if(variant.type() >= Variant::Type::I8Vector && variant.type() <= Variant::Type::C64Vector)
    {
        size_t len = 0;
        ByteArray data;
        switch(variant.type())
        {
        case Variant::Type::I8Vector: toCharsVector<I8Vector>(variant, len, data); break;
        case Variant::Type::UI8Vector: toCharsVector<UI8Vector>(variant, len, data); break;
        case Variant::Type::I16Vector: toCharsVector<I16Vector>(variant, len, data); break;
        case Variant::Type::UI16Vector: toCharsVector<UI16Vector>(variant, len, data); break;
        case Variant::Type::I32Vector: toCharsVector<I32Vector>(variant, len, data); break;
        case Variant::Type::UI32Vector: toCharsVector<UI32Vector>(variant, len, data); break;
        case Variant::Type::I64Vector: toCharsVector<I64Vector>(variant, len, data); break;
        case Variant::Type::UI64Vector: toCharsVector<UI64Vector>(variant, len, data); break;
        case Variant::Type::F32Vector: toCharsVector<F32Vector>(variant, len, data); break;
        case Variant::Type::F64Vector: toCharsVector<F64Vector>(variant, len, data); break;
        case Variant::Type::C32Vector: toCharsVector<C32Vector>(variant, len, data); break;
        case Variant::Type::C64Vector: toCharsVector<C64Vector>(variant, len, data); break;
        default: break;
        }
        node.append_attribute("length").set_value(len);
        node.append_attribute("location").set_value("inline:base64");
        node.append_child(pugi::node_pcdata).set_value(data.constData());
    }
    else if(variant.type() >= Variant::Type::I8Matrix && variant.type() <= Variant::Type::C64Matrix)
    {
        size_t rows = 0;
        size_t cols = 0;
        ByteArray data;
        switch(variant.type())
        {
        case Variant::Type::I8Matrix: toCharsMatrix<I8Matrix>(variant, rows, cols, data); break;
        case Variant::Type::UI8Matrix: toCharsMatrix<UI8Matrix>(variant, rows, cols, data); break;
        case Variant::Type::I16Matrix: toCharsMatrix<I16Matrix>(variant, rows, cols, data); break;
        case Variant::Type::UI16Matrix: toCharsMatrix<UI16Matrix>(variant, rows, cols, data); break;
        case Variant::Type::I32Matrix: toCharsMatrix<I32Matrix>(variant, rows, cols, data); break;
        case Variant::Type::UI32Matrix: toCharsMatrix<UI32Matrix>(variant, rows, cols, data); break;
        case Variant::Type::I64Matrix: toCharsMatrix<I64Matrix>(variant, rows, cols, data); break;
        case Variant::Type::UI64Matrix: toCharsMatrix<UI64Matrix>(variant, rows, cols, data); break;
        case Variant::Type::F32Matrix: toCharsMatrix<F32Matrix>(variant, rows, cols, data); break;
        case Variant::Type::F64Matrix: toCharsMatrix<F64Matrix>(variant, rows, cols, data); break;
        case Variant::Type::C32Matrix: toCharsMatrix<C32Matrix>(variant, rows, cols, data); break;
        case Variant::Type::C64Matrix: toCharsMatrix<C64Matrix>(variant, rows, cols, data); break;
        default: break;
        }

        node.append_attribute("rows").set_value(rows);
        node.append_attribute("columns").set_value(cols);
        node.append_attribute("location").set_value("inline:base64");
        node.append_child(pugi::node_pcdata).set_value(data.constData());
    }
    else if(variant.type() == Variant::Type::TimePoint)
    {
        std::ostringstream ss;
        ss << std::put_time(&variant.value<TimePoint>(), "%Y-%m-%dT%H:%M:%SZ");
        node.append_attribute("value").set_value(ss.str().c_str());
    }
}
Variant variantFromString(Variant::Type type, const String &str)
{
    Variant variant;
    switch(type)
    {
    case Variant::Type::Int32: variant = fromChars<Int32>(str.c_str(), str.c_str() + str.size()); break;
    case Variant::Type::Float32: variant = std::stof(str); break;
    case Variant::Type::Float64: variant = std::stod(str); break;
    case Variant::Type::String: variant = str; break;
    case Variant::Type::TimePoint:
    {
        std::istringstream ss(str);
        std::tm tm = {};
        ss >> std::get_time(&tm, "%Y-%m-%dT%H:%M:%SZ");
        variant = tm;
        break;
    }
    default: break;
    }
    return variant;
}

Variant::Type Variant::type() const
{
    return (Variant::Type)_value.index();
}

const char* Variant::typeName() const
{
    if(idToType.count(type()))
        return idToType[type()];
    else
        return "";
}

String Variant::toString() const
{
    std::string string;
    char str[32] = {0};
    char *end = str + sizeof(str);

    auto vectorString = [](auto &vector) {
        std::stringstream ss;
        ss << "{";
        for(auto &i : vector)
        {
            ss << i;
            if(i != vector.back())
                ss << ",";
        }
        ss << "}";
        return ss.str();
    };

    auto matrixString = [](auto matrix) {
        std::stringstream ss;
        ss << "{";
        for(int i=0; i<matrix.rows(); i++)
        {
            ss << "{";
            for(int o=0; o<matrix.cols(); o++)
            {
#if __GNUC__ >= 11 || __clang_major__ >= 15
                char str[128] = {0};
                char *end = str + sizeof(str);
                std::to_chars(str, end, matrix(i, o));
                ss << str;
#else
                ss << std::to_string(matrix(i, o));
#endif
                if(o < matrix.cols() - 1)
                    ss << ",";
            }
            ss << "}";
            if(i < matrix.rows() - 1)
                ss << ",";
        }
        return ss.str();
    };

    switch(type())
    {
    case Variant::Type::Int8: toChars<Int8>(_value, str, end); break;
    case Variant::Type::UInt8: toChars<UInt8>(_value, str, end); break;
    case Variant::Type::Int16: toChars<Int16>(_value, str, end); break;
    case Variant::Type::UInt16: toChars<UInt16>(_value, str, end); break;
    case Variant::Type::Int32: toChars<Int32>(_value, str, end); break;
    case Variant::Type::UInt32: toChars<UInt32>(_value, str, end); break;
    case Variant::Type::Int64: toChars<Int64>(_value, str, end); break;
    case Variant::Type::UInt64: toChars<UInt64>(_value, str, end); break;
    case Variant::Type::Float32: string = std::to_string(std::get<Float32>(_value)); break;
    case Variant::Type::Float64: string = std::to_string(std::get<Float64>(_value)); break;
    case Variant::Type::Complex32: toCharsComplex<Complex32>(_value, string); break;
    case Variant::Type::Complex64: toCharsComplex<Complex64>(_value, string); break;
    case Variant::Type::I8Vector: string = vectorString(std::get<I8Vector>(_value)); break;
    case Variant::Type::UI8Vector: string = vectorString(std::get<UI8Vector>(_value)); break;
    case Variant::Type::I16Vector: string = vectorString(std::get<I16Vector>(_value)); break;
    case Variant::Type::UI16Vector: string = vectorString(std::get<UI16Vector>(_value)); break;
    case Variant::Type::I32Vector: string = vectorString(std::get<I32Vector>(_value)); break;
    case Variant::Type::UI32Vector: string = vectorString(std::get<UI32Vector>(_value)); break;
    case Variant::Type::I64Vector: string = vectorString(std::get<I64Vector>(_value)); break;
    case Variant::Type::UI64Vector: string = vectorString(std::get<UI64Vector>(_value)); break;
    case Variant::Type::F32Vector: string = vectorString(std::get<F32Vector>(_value)); break;
    case Variant::Type::F64Vector: string = vectorString(std::get<F64Vector>(_value)); break;
    case Variant::Type::F32Matrix: string = matrixString(std::get<F32Matrix>(_value)); break;
    case Variant::Type::F64Matrix: string = matrixString(std::get<F64Matrix>(_value)); break;
    case Variant::Type::String: string = std::get<String>(_value); break;
    case Variant::Type::TimePoint:
    {
        std::ostringstream ss;
        ss << std::put_time(&std::get<TimePoint>(_value), "%Y-%m-%dT%H:%M:%SZ");
        string = ss.str();
        break;
    }
    default: string = typeName(); break;
    }

    if(type() >= Variant::Type::Int8 && type() <= Variant::Type::UInt64)
        string = str;

    return string;
}

}
