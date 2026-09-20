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

/* One shared CPU vendor policy for C and C++ callers. */
#include "my_hygon.h"

#if defined(_MSC_VER) && (defined(_M_X64) || defined(_M_IX86))
#include <intrin.h>
#elif defined(__GNUC__) && (defined(__i386__) || defined(__x86_64__))
#include <cpuid.h>
#endif

static inline int my_hygon_vendor_matches(unsigned int ebx, unsigned int edx,
                                         unsigned int ecx) {
  /* CPUID vendor string: HygonGenuine (EBX, EDX, ECX). */
  return ebx == 0x6f677948U && edx == 0x6e65476eU && ecx == 0x656e6975U;
}

static int my_cpu_detect_hygon(void) {
#if defined(_MSC_VER) && (defined(_M_X64) || defined(_M_IX86))
  int regs[4];
  __cpuid(regs, 0);
  return my_hygon_vendor_matches((unsigned int)regs[1],
                                (unsigned int)regs[3], (unsigned int)regs[2]);
#elif defined(__GNUC__) && (defined(__i386__) || defined(__x86_64__))
  unsigned int eax, ebx, ecx, edx;
  if (!__get_cpuid(0, &eax, &ebx, &ecx, &edx)) return 0;
  return my_hygon_vendor_matches(ebx, edx, ecx);
#else
  /* CPU vendor detection is unavailable on this target/toolchain.
     Use the generic code path. */
  return 0;
#endif
}

extern "C" int my_cpu_is_hygon(void) {
  /* Thread-safe first-use initialization, shared by C and C++ callers. */
  static const int my_cpu_is_hygon_cached = my_cpu_detect_hygon();
  return my_cpu_is_hygon_cached;
}
