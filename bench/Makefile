XDG = /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
frametap: frametap.c xdg-shell-client-protocol.h xdg-shell-protocol.c
	$(CC) -O2 -Wall -o $@ frametap.c xdg-shell-protocol.c $$(pkg-config --cflags --libs wayland-client)
xdg-shell-client-protocol.h: $(XDG)
	wayland-scanner client-header $< $@
xdg-shell-protocol.c: $(XDG)
	wayland-scanner private-code $< $@
clean:
	rm -f frametap xdg-shell-client-protocol.h xdg-shell-protocol.c
