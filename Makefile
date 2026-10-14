.PHONY: deb overlay clean distclean

deb:
	./build-deb.sh

# Remove outputs but keep the source checkout and cached original .deb
clean:
	rm -rf build/pkg build/*+patched.*.deb

distclean:
	rm -rf build

# Patch the installed Positron in place (e.g. Arch/AUR), no .deb
overlay:
	./build-deb.sh --overlay
