#!/usr/bin/env bash
set -Eeuo pipefail

[ -f versions.json ] # run "versions.sh" first

jqt='.jq-template.awk'
if [ -n "${BASHBREW_SCRIPTS:-}" ]; then
	jqt="$BASHBREW_SCRIPTS/jq-template.awk"
elif [ "$BASH_SOURCE" -nt "$jqt" ]; then
	# https://github.com/docker-library/bashbrew/blob/master/scripts/jq-template.awk
	wget -qO "$jqt" 'https://github.com/docker-library/bashbrew/raw/9f6a35772ac863a0241f147c820354e4008edf38/scripts/jq-template.awk'
fi

if [ "$#" -eq 0 ]; then
	versions="$(jq -r 'keys | map(@sh) | join(" ")' versions.json)"
	eval "set -- $versions"
fi

generated_warning() {
	cat <<-EOH
		#
		# NOTE: THIS DOCKERFILE IS GENERATED VIA "apply-templates.sh"
		#
		# PLEASE DO NOT EDIT IT DIRECTLY.
		#

	EOH
}

for version; do
	export version

	rm -rf "$version"

	if jq -e '.[env.version] | not' versions.json > /dev/null; then
		echo "deleting $version ..."
		continue
	fi

	variants="$(jq -r '.[env.version].variants | map(@sh) | join(" ")' versions.json)"
	eval "variants=( $variants )"

	for dir in "${variants[@]}"; do
		suite="$(dirname "$dir")" # "buster", etc
		variant="$(basename "$dir")" # "cli", etc
		export suite variant

		alpineVer="${suite#alpine}" # "3.12", etc
		if [ "$suite" != "$alpineVer" ]; then
			from="europe-west10-docker.pkg.dev/futalis-1544014797945/images/httpd:2.4-alpine$alpineVer"
			if [ "$variant" == "cli" ]; then
			    from="alpine:$alpineVer"
			fi
		else
			from="debian:$suite-slim"
		fi
		export from alpineVer variant

		case "$variant" in
			apache) cmd='["apache2-foreground"]' ;;
			fpm | fpm-zts) cmd='["php-fpm"]' ;;
			*) cmd='["php", "-a"]' ;;
		esac
		export cmd

		echo "processing $version/$dir ..."
		mkdir -p "$version/$dir"

		{
			generated_warning
			if [ "$suite" != "$alpineVer" ]; then
			    if [ "$version" == "8.0" ]; then
			        gawk -f "$jqt" 'Dockerfile-openssl1.1-builder';
                fi
			    gawk -f "$jqt" 'Dockerfile-curlbuilder';
            fi
			gawk -f "$jqt" 'Dockerfile-linux.template'
		} > "$version/$dir/Dockerfile"

		cp -a \
			docker-php-entrypoint \
			docker-php-ext-* \
			docker-php-source \
			"$version/$dir/"
		if [ "$variant" = 'apache' ]; then
			cp -a apache2-foreground "$version/$dir/"
		fi
		if [ "$suite" != "$alpineVer" ]; then
		    cp -ar curl "$version/$dir/"
		    if [ "$version" == "8.0" ]; then
		        sed -i 's/openssl-dev>3/openssl1.1-compat-dev/g' "$version/$dir/curl/APKBUILD"
		        cp -ar openssl1.1-compat "$version/$dir/"
		    fi
		fi

		cmd="$(jq <<<"$cmd" -r '.[0]')"
		if [ "$cmd" != 'php' ]; then
			sed -i -e 's! php ! '"$cmd"' !g' "$version/$dir/docker-php-entrypoint"
		fi
	done
done
