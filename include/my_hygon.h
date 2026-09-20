/* Copyright (c) 2026, Chengdu Haiguang IC Design Co., Ltd. All rights reserved.

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License, version 2.0,
  as published by the Free Software Foundation.

  This program is also distributed with certain software (including
  but not limited to OpenSSL) that is licensed under separate terms,
  as designated in a particular file or component or in included license
  documentation.  The authors of MySQL hereby grant you an additional
  permission to link the program and your derivative works with the
  separately licensed software that they have included with MySQL.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License, version 2.0, for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301  USA */

/* Runtime CPU selection shared by the server and bundled zlib. */
#ifndef MY_HYGON_INCLUDED
#define MY_HYGON_INCLUDED

#ifdef __cplusplus
extern "C" {
#endif
/* Return the cached CPU vendor result: 1 for Hygon, 0 otherwise.
   Initialized once on first access, including calls from static initializers.
   C and C++ callers share the same thread-safe function-local cache.
   This C ABI is implemented in C++ and requires the C++ runtime when linked
   statically. Use a C++ linker driver, or supply the matching runtime when
   using a C driver (for GCC, place -lstdc++ after the static libraries). */
int my_cpu_is_hygon(void);
#ifdef __cplusplus
}

#endif
#endif
