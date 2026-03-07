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

#include "streambuffer.h"

namespace LibXISF
{

StreamBuffer::StreamBuffer()
{
    setg(nullptr, nullptr, nullptr);
    setp(nullptr, nullptr);
}

StreamBuffer::StreamBuffer(const ByteArray &byteArray) :
    _size(byteArray.size()),
    _byteArray(byteArray)
{
    if(_byteArray.size())
    {
        char *ptr = _byteArray.data();
        setg(ptr, ptr, ptr + _size);
        setp(ptr, ptr + _size);
    }
    else
    {
        setg(nullptr, nullptr, nullptr);
        setp(nullptr, nullptr);
    }
}

ByteArray StreamBuffer::byteArray()
{
    return _byteArray;
}

StreamBuffer::pos_type StreamBuffer::seekoff(off_type off, std::ios_base::seekdir dir, std::ios_base::openmode mode)
{
    pos_type ret = pos_type(off_type(-1));
    off_type newoffi = off;
    off_type newoffo = off;
    if(dir == std::ios_base::cur)
    {
        newoffi += gptr() - eback();
        newoffo += pptr() - pbase();
    }
    else if(dir == std::ios_base::end)
        newoffo = newoffi = _byteArray.size() - off;

    char *ptr = _byteArray.data();
    if(mode & std::ios_base::in && newoffi >= 0 && newoffi <= _size)
    {
        setg(ptr, ptr + newoffi, ptr + _size);
        ret = pos_type(newoffi);
    }

    if(mode & std::ios_base::out && newoffo >= 0 && newoffo <= _size)
    {
        setp(ptr, ptr + _size);
        pbump(newoffo);
        ret = pos_type(newoffo);
    }

    return ret;
}

StreamBuffer::pos_type StreamBuffer::seekpos(pos_type pos, std::ios_base::openmode mode)
{
    pos_type ret = pos_type(off_type(-1));
    off_type off = pos;

    if(off >= 0 && off <= (off_type)_byteArray.size())
    {
        char *ptr = _byteArray.data();
        if(mode & std::ios_base::in)
            setg(ptr, ptr + pos, ptr + _size);

        if(mode & std::ios_base::out)
        {
            setp(ptr, ptr + _size);
            pbump(pos);
        }

        ret = pos;
    }
    return ret;
}

std::streamsize StreamBuffer::xsgetn(char_type *s, std::streamsize n)
{
    std::streamsize ret = 0;
    std::streamsize len = egptr() - gptr();
    if(len > 0)
    {
        std::streamsize c = n < len ? n : len;
        std::memcpy(s, gptr(), c);
        gbump(c);
        ret = c;
    }
    return ret;
}

StreamBuffer::int_type StreamBuffer::underflow()
{
    if(gptr() < egptr())
        return traits_type::to_int_type(*gptr());
    else
        return traits_type::eof();
}

std::streamsize StreamBuffer::xsputn(const char_type *s, std::streamsize n)
{
    off_type len = epptr() - pptr();
    if(len < n)
    {
        _size += n - len;
        _byteArray.resize(_size);
        update_ptrs();
    }
    std::memcpy(pptr(), s, n);
    pbump(n);
    return n;
}

StreamBuffer::int_type StreamBuffer::overflow(int_type c)
{
    if(traits_type::eq_int_type(traits_type::eof(), c))
        return traits_type::eof();

    _byteArray.append(c);
    _size++;
    pbump(1);
    update_ptrs();
    return c;
}

void StreamBuffer::update_ptrs()
{
    off_type ipos = gptr() - eback();
    off_type opos = pptr() - pbase();
    char *ptr = _byteArray.data();
    setg(ptr, ptr + ipos, ptr + _size);
    setp(ptr, ptr + _size);
    pbump(opos);
}

}
