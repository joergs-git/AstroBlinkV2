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

namespace LibXISF
{

void ByteArray::makeUnique()
{
    if(!_data.unique())
        _data = std::make_unique<PtrType>(_data->begin(), _data->end());
}

ByteArray::ByteArray(size_t size)
{
    _data = std::make_shared<std::vector<char>>();
    _data->resize(size);
}

ByteArray::ByteArray(const char *ptr) : ByteArray((size_t)0)
{
    size_t len = std::strlen(ptr);
    if(len)
    {
        _data->resize(len);
        std::memcpy(data(), ptr, len);
    }
}

ByteArray::ByteArray(const ByteArray &d)
{
    _data = d._data;
}

char& ByteArray::operator[](size_t i)
{
    makeUnique();
    return (*_data)[i];
}

const char& ByteArray::operator[](size_t i) const
{
    return (*_data)[i];
}

size_t ByteArray::size() const
{
    return _data->size();
}

void ByteArray::resize(size_t newsize)
{
    makeUnique();
    _data->resize(newsize);
}

void ByteArray::append(char c)
{
    _data->push_back(c);
}

void ByteArray::decodeBase64()
{
    int i = 0;
    Ptr tmp = std::make_unique<PtrType>();

    uint8_t c4[4] = {0};
    for(uint8_t c : *_data)
    {
        if(c >= 'A' && c <= 'Z')c4[i++] = c - 'A';
        else if(c >= 'a' && c <= 'z')c4[i++] = c - 'a' + 26;
        else if(c >= '0' && c <= '9')c4[i++] = c - '0' + 52;
        else if(c == '+')c4[i++] = 62;
        else if(c == '/')c4[i++] = 63;

        if(i == 4)
        {
            tmp->push_back((c4[0] << 2) | (c4[1] >> 4));
            tmp->push_back((c4[1] << 4) | (c4[2] >> 2));
            tmp->push_back((c4[2] << 6) | c4[3]);
            i = 0;
        }
    }

    if(i > 1)tmp->push_back((c4[0] << 2) | (c4[1] >> 4));
    if(i > 2)tmp->push_back((c4[1] << 4) | (c4[2] >> 2));

    std::swap(_data, tmp);
}

void ByteArray::encodeBase64()
{
    static const char *base64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    Ptr tmp = std::make_unique<PtrType>();
    int i = 0;
    uint8_t sextet[4] = {0};
    for(uint8_t c : *_data)
    {
        switch(i)
        {
        case 0:
            sextet[0] |= c >> 2 & 0x3f;
            sextet[1] |= c << 4 & 0x3f;
            i++;
            break;
        case 1:
            sextet[1] |= c >> 4 & 0x3f;
            sextet[2] |= c << 2 & 0x3f;
            i++;
            break;
        case 2:
            sextet[2] |= c >> 6 & 0x3f;
            sextet[3] = c & 0x3f;
            i = 0;
            for(int o=0; o<4; o++)
                tmp->push_back(base64[sextet[o]]);
            std::memset(sextet, 0, sizeof(sextet));
            break;
        }
    }
    for(int o = 0; o <= i && i; o++)
        tmp->push_back(base64[sextet[o]]);

    if(tmp->size() % 4)
        tmp->resize(tmp->size() + 4 - (tmp->size() % 4), '=');
    std::swap(_data, tmp);
}


void ByteArray::encodeHex()
{
    static const char *hex = "0123456789abcdef";
    Ptr tmp = std::make_unique<PtrType>(_data->size() * 2);
    for(size_t i = 0; i< _data->size(); i++)
    {
        uint8_t t = static_cast<uint8_t>(_data->at(i));
        (*tmp)[2*i + 0] = hex[(t & 0xf0) >> 4];
        (*tmp)[2*i + 1] = hex[t & 0xf];
    }
    std::swap(_data, tmp);
}

void ByteArray::decodeHex()
{
    auto toByte = [](char c) -> char
    {
        if(c >= '0' && c <= '9')
            return c - '0';
        if(c >= 'A' && c <= 'F')
            return c - '7';
        if(c >= 'a' && c <= 'f')
            return c - 'W';
        return 0;
    };

    Ptr tmp = std::make_unique<PtrType>(size() / 2);
    for(size_t i = 0; i< tmp->size(); i++)
    {
        (*tmp)[i] = (toByte(_data->at(i*2)) << 4) | toByte(_data->at(i*2+1));
    }
    std::swap(_data, tmp);
}

}
