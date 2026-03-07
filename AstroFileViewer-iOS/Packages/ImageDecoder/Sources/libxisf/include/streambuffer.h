/************************************************************************
 * LibXISF - library to load and save XISF files                        *
 * Copyright (C) 2024 Dušan Poizl                                       *
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

#ifndef STREAMBUFFER_H
#define STREAMBUFFER_H

#include <streambuf>
#include "libxisf.h"

namespace LibXISF
{

class StreamBuffer : public std::streambuf
{
public:
    StreamBuffer();
    StreamBuffer(const ByteArray &byteArray);
    ByteArray byteArray();
protected:
    pos_type seekoff(off_type off, std::ios_base::seekdir dir, std::ios_base::openmode mode = std::ios_base::in | std::ios_base::out) override;
    pos_type seekpos(pos_type pos, std::ios_base::openmode mode = std::ios_base::in | std::ios_base::out) override;

    std::streamsize xsgetn(char_type *s, std::streamsize n) override;
    int_type underflow() override;

    std::streamsize xsputn(const char_type *s, std::streamsize n) override;
    int_type overflow(int_type c = traits_type::eof()) override;
private:
    void update_ptrs();
    off_type _size = 0;
    ByteArray _byteArray;
};

}

#endif // STREAMBUFFER_H
