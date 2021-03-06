// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module builtin

import strconv
/*
NB: A V string should be/is immutable from the point of view of
    V user programs after it is first created. A V string is
    also slightly larger than the equivalent C string because
    the V string also has an integer length attached.

    This tradeoff is made, since V strings are created just *once*,
    but potentially used *many times* over their lifetime.

    The V string implementation uses a struct, that has a .str field,
    which points to a C style 0 terminated memory block. Although not
    strictly necessary from the V point of view, that additional 0
    is *very useful for C interoperability*.

    The V string implementation also has an integer .len field,
    containing the length of the .str field, excluding the
    terminating 0 (just like the C's strlen(s) would do).

    The 0 ending of .str, and the .len field, mean that in practice:
      a) a V string s can be used very easily, wherever a
         C string is needed, just by passing s.str,
         without a need for further conversion/copying.

      b) where strlen(s) is needed, you can just pass s.len,
         without having to constantly recompute the length of s
         *over and over again* like some C programs do. This is because
         V strings are immutable and so their length does not change.

    Ordinary V code *does not need* to be concerned with the
    additional 0 in the .str field. The 0 *must* be put there by the
    low level string creating functions inside this module.

    Failing to do this will lead to programs that work most of the
    time, when used with pure V functions, but fail in strange ways,
    when used with modules using C functions (for example os and so on).
*/


pub struct string {
pub:
	str byteptr // points to a C style 0 terminated string of bytes.
	len int // the length of the .str field, excluding the ending 0 byte. It is always equal to strlen(.str).
}
	// mut:
	// hash_cache int

pub struct ustring {
pub:
	s     string
	runes []int
	len   int
}

pub fn vstrlen(s byteptr) int {
	return C.strlen(charptr(s))
}

// Converts a C string to a V string.
// String data is reused, not copied.
pub fn tos(s byteptr, len int) string {
	// This should never happen.
	if s == 0 {
		panic('tos(): nil string')
	}
	return string{
		str: s
		len: len
	}
}

pub fn tos_clone(s byteptr) string {
	if s == 0 {
		panic('tos: nil string')
	}
	return tos2(s).clone()
}

// Same as `tos`, but calculates the length. Called by `string(bytes)` casts.
// Used only internally.
pub fn tos2(s byteptr) string {
	if s == 0 {
		panic('tos2: nil string')
	}
	return string{
		str: s
		len: vstrlen(s)
	}
}

// Same as `tos2`, but for char*, to avoid warnings
pub fn tos3(s charptr) string {
	if s == 0 {
		panic('tos3: nil string')
	}
	return string{
		str: byteptr(s)
		len: C.strlen(s)
	}
}

pub fn (a string) clone() string {
	mut b := string{
		len: a.len
		str: malloc(a.len + 1)
	}
	for i in 0..a.len {
		b.str[i] = a.str[i]
	}
	b.str[a.len] = `\0`
	return b
}

/*
pub fn (s string) cstr() byteptr {
	clone := s.clone()
	return clone.str
}
*/

// cstring_to_vstring creates a copy of cstr and turns it into a v string
pub fn cstring_to_vstring(cstr byteptr) string {
	slen := C.strlen(cstr)
	mut s := byteptr(memdup(cstr, slen + 1))
	s[slen] = `\0`
	return tos(s, slen)
}

pub fn (s string) replace_once(rep, with string) string {
	index := s.index(rep) or {
		return s
	}
	return s.substr(0, index) + with + s.substr(index + rep.len, s.len)
}

pub fn (s string) replace(rep, with string) string {
	if s.len == 0 || rep.len == 0 {
		return s
	}
	// TODO PERF Allocating ints is expensive. Should be a stack array
	// Get locations of all reps within this string
	mut idxs := []int
	mut idx := 0
	for {
		idx = s.index_after(rep, idx)
		if idx == -1 {
			break
		}
		idxs << idx
		idx += rep.len
	}
	// Dont change the string if there's nothing to replace
	if idxs.len == 0 {
		return s
	}
	// Now we know the number of replacements we need to do and we can calc the len of the new string
	new_len := s.len + idxs.len * (with.len - rep.len)
	mut b := malloc(new_len + 1) // add a newline just in case
	// Fill the new string
	mut idx_pos := 0
	mut cur_idx := idxs[idx_pos]
	mut b_i := 0
	for i := 0; i < s.len; i++ {
		if i == cur_idx {
			// Reached the location of rep, replace it with "with"
			for j in 0..with.len {
				b[b_i] = with[j]
				b_i++
			}
			// Skip the length of rep, since we just replaced it with "with"
			i += rep.len - 1
			// Go to the next index
			idx_pos++
			if idx_pos < idxs.len {
				cur_idx = idxs[idx_pos]
			}
		}
		else {
			// Rep doesnt start here, just copy
			b[b_i] = s[i]
			b_i++
		}
	}
	b[new_len] = `\0`
	return tos(b, new_len)
}

struct RepIndex {
	idx     int
	val_idx int
}

fn compare_rep_index(a, b &RepIndex) int {
	if a.idx < b.idx {
		return -1
	}
	if a.idx > b.idx {
		return 1
	}
	return 0
}


fn (a mut []RepIndex) sort() {
	a.sort_with_compare(compare_rep_index)
}

// TODO
/*
fn (a RepIndex) < (b RepIndex) bool {
	return a.idx < b.idx
}
*/


pub fn (s string) replace_each(vals []string) string {
	if s.len == 0 || vals.len == 0 {
		return s
	}
	if vals.len % 2 != 0 {
		println('string.replace_many(): odd number of strings')
		return s
	}
	// `rep` - string to replace
	// `with` - string to replace with
	// Remember positions of all rep strings, and calculate the length
	// of the new string to do just one allocation.
	mut new_len := s.len
	mut idxs := []RepIndex
	mut idx := 0
	for rep_i := 0; rep_i < vals.len; rep_i += 2 {
		// vals: ['rep1, 'with1', 'rep2', 'with2']
		rep := vals[rep_i]
		with := vals[rep_i + 1]
		for {
			idx = s.index_after(rep, idx)
			if idx == -1 {
				break
			}
			// We need to remember both the position in the string,
			// and which rep/with pair it refers to.
			idxs << RepIndex {
				idx:idx
				val_idx:rep_i
			}
			idx++
			new_len += with.len - rep.len
		}
	}
	// Dont change the string if there's nothing to replace
	if idxs.len == 0 {
		return s
	}
	idxs.sort()
	mut b := malloc(new_len + 1) // add a \0 just in case
	// Fill the new string
	mut idx_pos := 0
	mut cur_idx := idxs[idx_pos]
	mut b_i := 0
	for i := 0; i < s.len; i++ {
		if i == cur_idx.idx {
			// Reached the location of rep, replace it with "with"
			rep := vals[cur_idx.val_idx]
			with := vals[cur_idx.val_idx + 1]
			for j in 0..with.len {
				b[b_i] = with[j]
				b_i++
			}
			// Skip the length of rep, since we just replaced it with "with"
			i += rep.len - 1
			// Go to the next index
			idx_pos++
			if idx_pos < idxs.len {
				cur_idx = idxs[idx_pos]
			}
		}
		else {
			// Rep doesnt start here, just copy
			b[b_i] = s.str[i]
			b_i++
		}
	}
	b[new_len] = `\0`
	return tos(b, new_len)
}

pub fn (s string) bool() bool {
	return s == 'true' || s == 't' // TODO t for pg, remove
}

pub fn (s string) int() int {
	return int(strconv.common_parse_int(s, 0, 32, false, false))
}

pub fn (s string) i64() i64 {
	return strconv.common_parse_int(s, 0, 64, false, false)
}

pub fn (s string) i8() i8 {
	return i8(strconv.common_parse_int(s, 0, 8, false, false))
}

pub fn (s string) i16() i16 {
	return i16(strconv.common_parse_int(s, 0, 16, false, false))
}

pub fn (s string) f32() f32 {
	// return C.atof(charptr(s.str))
	return f32(strconv.atof64(s))
}

pub fn (s string) f64() f64 {
	// return C.atof(charptr(s.str))
	return strconv.atof64(s)
}

pub fn (s string) u16() u16 {
	return u16(strconv.common_parse_uint(s, 0, 16, false, false))
}

pub fn (s string) u32() u32 {
	return u32(strconv.common_parse_uint(s, 0, 32, false, false))
}

pub fn (s string) u64() u64 {
	return strconv.common_parse_uint(s, 0, 64, false, false)
}

// ==
fn (s string) eq(a string) bool {
	if isnil(s.str) {
		// should never happen
		panic('string.eq(): nil string')
	}
	if s.len != a.len {
		return false
	}
	for i in 0..s.len {
		if s[i] != a[i] {
			return false
		}
	}
	return true
}

// !=
fn (s string) ne(a string) bool {
	return !s.eq(a)
}

// s < a
fn (s string) lt(a string) bool {
	for i in 0..s.len {
		if i >= a.len || s[i] > a[i] {
			return false
		}
		else if s[i] < a[i] {
			return true
		}
	}
	if s.len < a.len {
		return true
	}
	return false
}

// s <= a
fn (s string) le(a string) bool {
	return s.lt(a) || s.eq(a)
}

// s > a
fn (s string) gt(a string) bool {
	return !s.le(a)
}

// s >= a
fn (s string) ge(a string) bool {
	return !s.lt(a)
}

// TODO `fn (s string) + (a string)` ? To be consistent with operator overloading syntax.
fn (s string) add(a string) string {
	new_len := a.len + s.len
	mut res := string{
		len: new_len
		str: malloc(new_len + 1)
	}
	for j in 0..s.len {
		res.str[j] = s.str[j]
	}
	for j in 0..a.len {
		res.str[s.len + j] = a.str[j]
	}
	res.str[new_len] = `\0` // V strings are not null terminated, but just in case
	return res
}

pub fn (s string) split(delim string) []string {
	return s.split_nth(delim, 0)
}

/*
split_nth - splits the string based on the passed `delim` substring.
It returns the first Nth parts. When N=0, return all the splits.
The last returned element has the remainder of the string, even if
the remainder contains more `delim` substrings.
*/
pub fn (s string) split_nth(delim string, nth int) []string {
	mut res := []string
	mut i := 0
	if delim.len == 0 {
		i = 1
		for ch in s {
			if nth > 0 && i >= nth {
				res << s.substr(i, s.len)
				break
			}
			res << ch.str()
			i++
		}
		return res
	}
	mut start := 0
	nth_1 := nth - 1
	for i <= s.len {
		mut is_delim := s.str[i] == delim.str[0]
		mut j := 0
		for is_delim && j < delim.len {
			is_delim = is_delim && s.str[i + j] == delim.str[j]
			j++
		}
		last := i == s.len - 1
		if is_delim || last {
			if !is_delim && last {
				i++
			}
			mut val := s.substr(start, i)
			if val.starts_with(delim) {
				val = val.right(delim.len)
			}

			was_last := nth > 0 && res.len == nth_1
			if was_last {
				res << s.right(start)
				break
			}

			res << val
			start = i + delim.len
		}
		i++
	}
	if s.ends_with(delim) && (nth < 1 || res.len < nth) {
		res << ''
	}
	return res
}

pub fn (s string) split_into_lines() []string {
	mut res := []string
	if s.len == 0 {
		return res
	}
	mut start := 0
	for i := 0; i < s.len; i++ {
		is_lf := s.str[i] == `\n`
		is_crlf := i != s.len - 1 && s.str[i] == `\r` && s.str[i + 1] == `\n`
		is_eol := is_lf || is_crlf
		is_last := if is_crlf {
			i == s.len - 2
		} else {
			i == s.len - 1
		}

		if is_eol || is_last {
			if is_last && !is_eol {
				i++
			}

			line := s.substr(start, i)
			res << line

			if is_crlf {
				i++
			}

			start = i + 1
		}
	}
	return res
}

// 'hello'.left(2) => 'he'
fn (s string) left(n int) string {
	if n >= s.len {
		return s
	}
	return s.substr(0, n)
}

// 'hello'.right(2) => 'llo'
fn (s string) right(n int) string {
	if n >= s.len {
		return ''
	}
	return s.substr(n, s.len)
}

// used internally for [2..4]
fn (s string) substr2(start, _end int, end_max bool) string {
	end := if end_max { s.len } else { _end }
	return s.substr(start, end)
}

pub fn (s string) substr(start, end int) string {
	$if !no_bounds_checking? {
		if start > end || start > s.len || end > s.len || start < 0 || end < 0 {
			panic('substr($start, $end) out of bounds (len=$s.len)')
		}
	}
	len := end - start
	mut res := string{
		len: len
		str: malloc(len + 1)
	}
	for i in 0..len {
		res.str[i] = s.str[start + i]
	}
	res.str[len] = `\0`
	/*
	res := string {
		str: s.str + start
		len: len
	}
*/

	return res
}

pub fn (s string) index_old(p string) int {
	if p.len > s.len || p.len == 0 {
		return -1
	}
	mut i := 0
	for i < s.len {
		mut j := 0
		for j < p.len && s.str[i + j] == p.str[j] {
			j++
		}
		if j == p.len {
			return i
		}
		i++
	}
	return -1
}

pub fn (s string) index(p string) ?int {
	if p.len > s.len || p.len == 0 {
		return none
	}
	mut i := 0
	for i < s.len {
		mut j := 0
		for j < p.len && s.str[i + j] == p.str[j] {
			j++
		}
		if j == p.len {
			return i
		}
		i++
	}
	return none
}

// KMP search
fn (s string) index_kmp(p string) int {
	if p.len > s.len {
		return -1
	}
	mut prefix := [0].repeat(p.len)
	mut j := 0
	for i := 1; i < p.len; i++ {
		for p.str[j] != p.str[i] && j > 0 {
			j = prefix[j - 1]
		}
		if p.str[j] == p.str[i] {
			j++
		}
		prefix[i] = j
	}
	j = 0
	for i in 0..s.len {
		for p.str[j] != s.str[i] && j > 0 {
			j = prefix[j - 1]
		}
		if p.str[j] == s.str[i] {
			j++
		}
		if j == p.len {
			return i - p.len + 1
		}
	}
	return -1
}

pub fn (s string) index_any(chars string) int {
	for c in chars {
		index := s.index(c.str()) or {
			continue
		}
		return index
	}
	return -1
}

pub fn (s string) last_index(p string) ?int {
	if p.len > s.len || p.len == 0 {
		return none
	}
	mut i := s.len - p.len
	for i >= 0 {
		mut j := 0
		for j < p.len && s.str[i + j] == p.str[j] {
			j++
		}
		if j == p.len {
			return i
		}
		i--
	}
	return none
}

pub fn (s string) index_after(p string, start int) int {
	if p.len > s.len {
		return -1
	}
	mut strt := start
	if start < 0 {
		strt = 0
	}
	if start >= s.len {
		return -1
	}
	mut i := strt
	for i < s.len {
		mut j := 0
		mut ii := i
		for j < p.len && s.str[ii] == p.str[j] {
			j++
			ii++
		}
		if j == p.len {
			return i
		}
		i++
	}
	return -1
}

pub fn (s string) index_byte(c byte) int {
	for i in 0..s.len {
		if s.str[i] == c {
			return i
		}
	}
	return -1
}

pub fn (s string) last_index_byte(c byte) int {
	for i := s.len - 1; i >= 0; i-- {
		if s.str[i] == c {
			return i
		}
	}
	return -1
}

// counts occurrences of substr in s
pub fn (s string) count(substr string) int {
	if s.len == 0 || substr.len == 0 {
		return 0
	}
	if substr.len > s.len {
		return 0
	}
	mut n := 0
	mut i := 0
	for {
		i = s.index_after(substr, i)
		if i == -1 {
			return n
		}
		i += substr.len
		n++
	}
	return 0 // TODO can never get here - v doesn't know that
}

pub fn (s string) contains(p string) bool {
	s.index(p) or {
		return false
	}
	return true
}

pub fn (s string) starts_with(p string) bool {
	if p.len > s.len {
		return false
	}
	for i in 0..p.len {
		if s.str[i] != p.str[i] {
			return false
		}
	}
	return true
}

pub fn (s string) ends_with(p string) bool {
	if p.len > s.len {
		return false
	}
	for i in 0..p.len {
		if p[i] != s[s.len - p.len + i] {
			return false
		}
	}
	return true
}

// TODO only works with ASCII
pub fn (s string) to_lower() string {
	mut b := malloc(s.len + 1)
	for i in 0..s.len {
		b[i] = C.tolower(s.str[i])
	}
	return tos(b, s.len)
}

pub fn (s string) is_lower() bool {
	for i in 0..s.len {
		if s[i] >= `A` && s[i] <= `Z` {
			return false
		}
	}
	return true
}

pub fn (s string) to_upper() string {
	mut b := malloc(s.len + 1)
	for i in 0..s.len {
		b[i] = C.toupper(s.str[i])
	}
	return tos(b, s.len)
}

pub fn (s string) is_upper() bool {
	for i in 0..s.len {
		if s[i] >= `a` && s[i] <= `z` {
			return false
		}
	}
	return true
}

pub fn (s string) capitalize() string {
	if s.len == 0 {
		return ''
	}
	sl := s.to_lower()
	cap := sl[0].str().to_upper() + sl.right(1)
	return cap
}

pub fn (s string) is_capital() bool {
	if s.len == 0 || !(s[0] >= `A` && s[0] <= `Z`) {
		return false
	}
	for i in 1..s.len {
		if s[i] >= `A` && s[i] <= `Z` {
			return false
		}
	}
	return true
}

pub fn (s string) title() string {
	words := s.split(' ')
	mut tit := []string
	for word in words {
		tit << word.capitalize()
	}
	title := tit.join(' ')
	return title
}

pub fn (s string) is_title() bool {
	words := s.split(' ')
	for word in words {
		if !word.is_capital() {
			return false
		}
	}
	return true
}

// 'hey [man] how you doin'
// find_between('[', ']') == 'man'
pub fn (s string) find_between(start, end string) string {
	start_pos := s.index(start) or {
		return ''
	}
	// First get everything to the right of 'start'
	val := s.right(start_pos + start.len)
	end_pos := val.index(end) or {
		return val
	}
	return val.left(end_pos)
}

// TODO generic
fn (ar []string) contains(val string) bool {
	for s in ar {
		if s == val {
			return true
		}
	}
	return false
}

// TODO generic
fn (ar []int) contains(val int) bool {
	for i, s in ar {
		if s == val {
			return true
		}
	}
	return false
}

/*
pub fn (a []string) to_c() voidptr {
	mut res := malloc(sizeof(byteptr) * a.len)
	for i in 0..a.len {
		val := a[i]
		res[i] = val.str
	}
	return res
}
*/

pub fn (c byte) is_space() bool {
	// 0x0085 is NEXT LINE (NEL)
	// 0x00a0 is NO-BREAK SPACE
	return c in [` `, `\n`, `\t`, `\v`, `\f`, `\r`, 0x85, 0xa0]
}

pub fn (s string) trim_space() string {
	return s.trim(' \n\t\v\f\r')
}

pub fn (s string) trim(cutset string) string {
	if s.len < 1 || cutset.len < 1 {
		return s
	}
	cs_arr := cutset.bytes()
	mut pos_left := 0
	mut pos_right := s.len - 1
	mut cs_match := true
	for pos_left <= s.len && pos_right >= -1 && cs_match {
		cs_match = false
		if s[pos_left] in cs_arr {
			pos_left++
			cs_match = true
		}
		if s[pos_right] in cs_arr {
			pos_right--
			cs_match = true
		}
		if pos_left > pos_right {
			return ''
		}
	}
	return s.substr(pos_left, pos_right + 1)
}

pub fn (s string) trim_left(cutset string) string {
	if s.len < 1 || cutset.len < 1 {
		return s
	}
	cs_arr := cutset.bytes()
	mut pos := 0
	for pos < s.len && s[pos] in cs_arr {
		pos++
	}
	return s.right(pos)
}

pub fn (s string) trim_right(cutset string) string {
	if s.len < 1 || cutset.len < 1 {
		return s
	}
	cs_arr := cutset.bytes()
	mut pos := s.len - 1
	for pos >= 0 && s[pos] in cs_arr {
		pos--
	}
	return if pos < 0 { '' } else { s.left(pos + 1) }
}

// fn print_cur_thread() {
// //C.printf("tid = %08x \n", pthread_self());
// }
fn compare_strings(a, b &string) int {
	if a.lt(b) {
		return -1
	}
	if a.gt(b) {
		return 1
	}
	return 0
}

fn compare_strings_by_len(a, b &string) int {
	if a.len < b.len {
		return -1
	}
	if a.len > b.len {
		return 1
	}
	return 0
}

fn compare_lower_strings(a, b &string) int {
	aa := a.to_lower()
	bb := b.to_lower()
	return compare_strings(aa, bb)
}

pub fn (s mut []string) sort() {
	s.sort_with_compare(compare_strings)
}

pub fn (s mut []string) sort_ignore_case() {
	s.sort_with_compare(compare_lower_strings)
}

pub fn (s mut []string) sort_by_len() {
	s.sort_with_compare(compare_strings_by_len)
}

pub fn (s ustring) str() string {
   return s.s
}

pub fn (s string) ustring() ustring {
	mut res := ustring{
		s: s
		// runes will have at least s.len elements, save reallocations
		// TODO use VLA for small strings?

		runes: new_array(0, s.len, sizeof(int))
	}
	for i := 0; i < s.len; i++ {
		char_len := utf8_char_len(s.str[i])
		res.runes << i
		i += char_len - 1
		res.len++
	}
	return res
}

// A hack that allows to create ustring without allocations.
// It's called from functions like draw_text() where we know that the string is going to be freed
// right away. Uses global buffer for storing runes []int array.
__global g_ustring_runes []int

pub fn (s string) ustring_tmp() ustring {
	if g_ustring_runes.len == 0 {
		g_ustring_runes = new_array(0, 128, sizeof(int))
	}
	mut res := ustring{
		s: s
	}
	res.runes = g_ustring_runes
	res.runes.len = s.len
	mut j := 0
	for i := 0; i < s.len; i++ {
		char_len := utf8_char_len(s.str[i])
		res.runes[j] = i
		j++
		i += char_len - 1
		res.len++
	}
	return res
}

fn (u ustring) eq(a ustring) bool {
	if u.len != a.len || u.s != a.s {
		return false
	}
	return true
}

fn (u ustring) ne(a ustring) bool {
	return !u.eq(a)
}

fn (u ustring) lt(a ustring) bool {
	return u.s < a.s
}

fn (u ustring) le(a ustring) bool {
	return u.lt(a) || u.eq(a)
}

fn (u ustring) gt(a ustring) bool {
	return !u.le(a)
}

fn (u ustring) ge(a ustring) bool {
	return !u.lt(a)
}

pub fn (u ustring) add(a ustring) ustring {
	mut res := ustring{
		s: u.s + a.s
		runes: new_array(0, u.s.len + a.s.len, sizeof(int))
	}
	mut j := 0
	for i := 0; i < u.s.len; i++ {
		char_len := utf8_char_len(u.s.str[i])
		res.runes << j
		i += char_len - 1
		j += char_len
		res.len++
	}
	for i := 0; i < a.s.len; i++ {
		char_len := utf8_char_len(a.s.str[i])
		res.runes << j
		i += char_len - 1
		j += char_len
		res.len++
	}
	return res
}

pub fn (u ustring) index_after(p ustring, start int) int {
	if p.len > u.len {
		return -1
	}
	mut strt := start
	if start < 0 {
		strt = 0
	}
	if start > u.len {
		return -1
	}
	mut i := strt
	for i < u.len {
		mut j := 0
		mut ii := i
		for j < p.len && u.at(ii) == p.at(j) {
			j++
			ii++
		}
		if j == p.len {
			return i
		}
		i++
	}
	return -1
}

// counts occurrences of substr in s
pub fn (u ustring) count(substr ustring) int {
	if u.len == 0 || substr.len == 0 {
		return 0
	}
	if substr.len > u.len {
		return 0
	}
	mut n := 0
	mut i := 0
	for {
		i = u.index_after(substr, i)
		if i == -1 {
			return n
		}
		i += substr.len
		n++
	}
	return 0 // TODO can never get here - v doesn't know that
}

pub fn (u ustring) substr(_start, _end int) string {
	$if !no_bounds_checking? {
		if _start > _end || _start > u.len || _end > u.len || _start < 0 || _end < 0 {
			panic('substr($_start, $_end) out of bounds (len=$u.len)')
		}
	}
	end := if _end >= u.len { u.s.len } else { u.runes[_end] }
	return u.s.substr(u.runes[_start], end)
}

pub fn (u ustring) left(pos int) string {
	if pos >= u.len {
		return u.s
	}
	return u.substr(0, pos)
}

pub fn (u ustring) right(pos int) string {
	if pos >= u.len {
		return ''
	}
	return u.substr(pos, u.len)
}

fn (s string) at(idx int) byte {
	$if !no_bounds_checking? {
		if idx < 0 || idx >= s.len {
			panic('string index out of range: $idx / $s.len')
		}
	}
	return s.str[idx]
}

pub fn (u ustring) at(idx int) string {
	$if !no_bounds_checking? {
		if idx < 0 || idx >= u.len {
			panic('string index out of range: $idx / $u.runes.len')
		}
	}
	return u.substr(idx, idx + 1)
}

fn (u ustring) free() {
	u.runes.free()
}

pub fn (c byte) is_digit() bool {
	return c >= `0` && c <= `9`
}

pub fn (c byte) is_hex_digit() bool {
	return c.is_digit() || (c >= `a` && c <= `f`) || (c >= `A` && c <= `F`)
}

pub fn (c byte) is_oct_digit() bool {
	return c >= `0` && c <= `7`
}

pub fn (c byte) is_bin_digit() bool {
	return c == `0` || c == `1`
}

pub fn (c byte) is_letter() bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`)
}

pub fn (s string) free() {
	free(s.str)
}

/*
fn (arr []string) free() {
	for s in arr {
		s.free()
	}
	C.free(arr.data)
}
*/

// all_before('23:34:45.234', '.') == '23:34:45'
pub fn (s string) all_before(dot string) string {
	pos := s.index(dot) or {
		return s
	}
	return s.left(pos)
}

pub fn (s string) all_before_last(dot string) string {
	pos := s.last_index(dot) or {
		return s
	}
	return s.left(pos)
}

pub fn (s string) all_after(dot string) string {
	pos := s.last_index(dot) or {
		return s
	}
	return s.right(pos + dot.len)
}

pub fn (s string) after(dot string) string { return s.all_after(dot) }

// fn (s []string) substr(a, b int) string {
// return join_strings(s.slice_fast(a, b))
// }
pub fn (a []string) join(del string) string {
	if a.len == 0 {
		return ''
	}
	mut len := 0
	for i, val in a {
		len += val.len + del.len
	}
	len -= del.len
	// Allocate enough memory
	mut res := ''
	res.len = len
	res.str = malloc(res.len + 1)
	mut idx := 0
	// Go thru every string and copy its every char one by one
	for i, val in a {
		for j in 0..val.len {
			res.str[idx] = val.str[j]
			idx++
		}
		// Add del if it's not last
		if i != a.len - 1 {
			for k in 0..del.len {
				res.str[idx] = del.str[k]
				idx++
			}
		}
	}
	res.str[res.len] = `\0`
	return res
}

pub fn (s []string) join_lines() string {
	return s.join('\n')
}

// reverse will return a new reversed string.
pub fn (s string) reverse() string {
	if s.len == 0 || s.len == 1 {
		return s
	}
	mut res := string{
		len: s.len
		str: malloc(s.len)
	}
	for i := s.len - 1; i >= 0; i-- {
		res.str[s.len - i - 1] = s[i]
	}
	return res
}

// limit returns a portion of the string, starting at `0` and extending for a given number of characters afterward.
// 'hello'.limit(2) => 'he'
// 'hi'.limit(10) => 'hi'
pub fn (s string) limit(max int) string {
	u := s.ustring()
	if u.len <= max {
		return s
	}
	return u.substr(0, max)
}

[deprecated]
pub fn (c byte) is_white() bool {
	panic('Use `string.is_space` instead of `string.is_white')
}

pub fn (s string) hash() int {
	// mut h := s.hash_cache
	mut h := 0
	if h == 0 && s.len > 0 {
		for c in s {
			h = h * 31 + int(c)
		}
	}
	return h
}

pub fn (s string) bytes() []byte {
	if s.len == 0 {
		return []
	}
	mut buf := [byte(0)].repeat(s.len)
	C.memcpy(buf.data, s.str, s.len)
	return buf
}

// repeat returns a new string with a specified number of copies of the string it was called on.
pub fn (s string) repeat(count int) string {
	if count < 0 {
		panic('string.repeat: count is negative: $count')
	} else if count == 0 {
		return ''
	} else if count == 1 {
		return s
	}
	mut ret := malloc(s.len * count + 1)
	for i in 0 .. count {
		for j in 0 .. s.len {
			ret[i * s.len + j] = s[j]
		}
	}
	ret[s.len * count] = 0
	return string(ret)
}

// Allows multi-line strings to be formatted in a way that removes white-space
// before a delimeter. by default `|` is used.
// Note: the delimiter has to be a byte at this time. That means surrounding
// the value in ``.
//
// Example:
// st := 'Hello there,
//       |this is a string,
//       |    Everything before the first | is removed'.strip_margin()
// Returns:
// Hello there,
// this is a string,
//     Everything before the first | is removed
pub fn (s string) strip_margin() string {
   return s.strip_margin_custom(`|`)
}
pub fn (s string) strip_margin_custom(del byte) string {
	mut sep := del
	if sep.is_space() {
		eprintln("Warning: `strip_margin` cannot use white-space as a delimiter")
		eprintln("    Defaulting to `|`")
		sep = `|`
	}
	// don't know how much space the resulting string will be, but the max it
	// can be is this big
	mut ret := malloc(s.len + 1)
	mut count := 0
	for i := 0; i < s.len; i++ {
		if s[i] in [`\n`, `\r`] {
			ret[count] = s[i]
			count++
			// CRLF
			if s[i] == `\r` && i < s.len - 1 && s[i+1] == `\n` {
				ret[count] = s[i+1]
				count++
				i++
			}

			for s[i] != sep {
				i++
				if i >= s.len {
					break
				}
			}
		} else {
			ret[count] = s[i]
			count++
		}
	}
	ret[count] = 0
	return string(ret)
}
