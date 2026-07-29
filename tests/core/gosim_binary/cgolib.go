package cgolib

/*
static int gosim_answer(void) {
	return 42;
}
*/
import "C"

import "example.com/gosim/cgohelper"

func Answer() int {
	return cgohelper.Normalize(int(C.gosim_answer()))
}
