/*
 * Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
 * IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
 * OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include "zmux-regex.h"

#include <stdlib.h>

void *
zmux_regex_new(void)
{
	return calloc(1, sizeof(regex_t));
}

int
zmux_regex_compile(void *ptr, const char *pattern, int flags)
{
	return regcomp((regex_t *)ptr, pattern, flags);
}

int
zmux_regex_exec(void *ptr, const char *text, size_t nmatch, regmatch_t *matches)
{
	return regexec((regex_t *)ptr, text, nmatch, matches, 0);
}

void
zmux_regex_free(void *ptr)
{
	if (ptr == NULL)
		return;
	regfree((regex_t *)ptr);
	free(ptr);
}
