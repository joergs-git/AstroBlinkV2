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

#include <vector>
#include <string>
#include <cstdint>

namespace LibXISF
{

std::vector<std::string> splitString(const std::string &str, char delimiter)
{
    std::vector<std::string> ret;
    size_t cur = 0;
    size_t prev = 0;
    while((cur = str.find(delimiter, prev)) != std::string::npos)
    {
        ret.push_back(str.substr(prev, cur - prev));
        prev = cur + 1;
    }
    if(!str.empty())
        ret.push_back(str.substr(prev));
    return ret;
}

void sha1(uint8_t *data, size_t len, uint8_t *hash)
{
    uint32_t h0 = 0x67452301;
    uint32_t h1 = 0xEFCDAB89;
    uint32_t h2 = 0x98BADCFE;
    uint32_t h3 = 0x10325476;
    uint32_t h4 = 0xC3D2E1F0;

    std::vector<uint8_t> tmp(data, data + len);
    tmp.push_back(0x80);
    size_t nlen = tmp.size() + 8;
    nlen += 64 - nlen % 64;
    tmp.resize(nlen, 0);

    uint64_t ml = len * 8;
    tmp[nlen - 1] = ml & 0xff;
    tmp[nlen - 2] = ml >>  8 & 0xff;
    tmp[nlen - 3] = ml >> 16 & 0xff;
    tmp[nlen - 4] = ml >> 24 & 0xff;
    tmp[nlen - 5] = ml >> 32 & 0xff;
    tmp[nlen - 6] = ml >> 40 & 0xff;
    tmp[nlen - 7] = ml >> 48 & 0xff;
    tmp[nlen - 8] = ml >> 56 & 0xff;

    for(size_t o = 0; o < nlen; o += 64)
    {
        uint32_t w[80];

        for(int i = 0; i < 16; i++)
        {
            w[i] = tmp[o + i * 4] << 24;
            w[i] |= tmp[o + i * 4 + 1] << 16;
            w[i] |= tmp[o + i * 4 + 2] << 8;
            w[i] |= tmp[o + i * 4 + 3];
        }

        for(int i = 16; i < 80; i++)
        {
            w[i] = w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16];
            w[i] = w[i] << 1 | w[i] >> 31;
        }

        uint32_t a = h0;
        uint32_t b = h1;
        uint32_t c = h2;
        uint32_t d = h3;
        uint32_t e = h4;

        for(int i = 0; i < 20; i++)
        {
            uint32_t f = (b & c) ^ (~b & d);
            uint32_t temp = (a << 5 | a >> 27) + f + e + 0x5A827999 + w[i];
            e = d; d = c; c = b << 30 | b >> 2; b = a; a = temp;
        }

        for(int i = 20; i < 40; i++)
        {
            uint32_t f = b ^ c ^ d;
            uint32_t temp = (a << 5 | a >> 27) + f + e + 0x6ED9EBA1 + w[i];
            e = d; d = c; c = b << 30 | b >> 2; b = a; a = temp;
        }

        for(int i = 40; i < 60; i++)
        {
            uint32_t f = (b & c) ^ (b & d) ^ (c & d);
            uint32_t temp = (a << 5 | a >> 27) + f + e + 0x8F1BBCDC + w[i];
            e = d; d = c; c = b << 30 | b >> 2; b = a; a = temp;
        }

        for(int i = 60; i < 80; i++)
        {
            uint32_t f = b ^ c ^ d;
            uint32_t temp = (a << 5 | a >> 27) + f + e + 0xCA62C1D6 + w[i];
            e = d; d = c; c = b << 30 | b >> 2; b = a; a = temp;
        }

        h0 += a;
        h1 += b;
        h2 += c;
        h3 += d;
        h4 += e;

    }
    hash[0]  = h0 >> 24 & 0xff; hash[1]  = h0 >> 16 & 0xff; hash[2]  = h0 >> 8 & 0xff; hash[3]  = h0 & 0xff;
    hash[4]  = h1 >> 24 & 0xff; hash[5]  = h1 >> 16 & 0xff; hash[6]  = h1 >> 8 & 0xff; hash[7]  = h1 & 0xff;
    hash[8]  = h2 >> 24 & 0xff; hash[9]  = h2 >> 16 & 0xff; hash[10] = h2 >> 8 & 0xff; hash[11] = h2 & 0xff;
    hash[12] = h3 >> 24 & 0xff; hash[13] = h3 >> 16 & 0xff; hash[14] = h3 >> 8 & 0xff; hash[15] = h3 & 0xff;
    hash[16] = h4 >> 24 & 0xff; hash[17] = h4 >> 16 & 0xff; hash[18] = h4 >> 8 & 0xff; hash[19] = h4 & 0xff;
}

}
