// Caddy entry point for the l4 variant; see README.md.
package main

import (
	caddycmd "github.com/caddyserver/caddy/v2/cmd"

	_ "github.com/caddyserver/caddy/v2/modules/standard"
	_ "github.com/dunglas/caddy-cbrotli"
	_ "github.com/dunglas/mercure/caddy"
	_ "github.com/mholt/caddy-l4"
)

func main() {
	caddycmd.Main()
}
