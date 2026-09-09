//go:build tinygo

package host

//export slung_alloc
func SlungAlloc(length uint32) uint32 {
	return allocBuffer(length)
}

//export slung_dealloc
func SlungDealloc(ptr, length uint32) {
	freeBuffer(ptr, length)
}
