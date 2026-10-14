.PHONY: deb clean distclean

deb:
	./build-deb.sh

# Remove outputs but keep the source checkout and cached original .deb
clean:
	rm -rf build/pkg build/*+patched.*.deb

distclean:
	rm -rf build
