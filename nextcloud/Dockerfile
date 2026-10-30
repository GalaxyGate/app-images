FROM nextcloud:35.0.2-apache@sha256:e0b1a2af52c82c07b7a0e8e59878bd8769e704447734d5d238a836982f51b9c8

# A GalaxyGate app domain ends TLS at the domain proxy, which reaches the
# container over plain http and sends X-Forwarded-Proto: https. NextCloud only
# reads that header from addresses listed in trusted_proxies, and the proxy
# pool has no fixed address range that excludes customer servers. Apache also
# completes the .htaccess redirects with its own scheme, which is always http
# here. galaxygate-proxy.conf turns the header into HTTPS=on for NextCloud and
# keeps those redirects on https. Requests straight to the server address carry
# no such header and stay plain http. ENTRYPOINT and CMD stay upstream's.
COPY galaxygate-proxy.conf /etc/apache2/conf-available/galaxygate-proxy.conf
RUN a2enconf galaxygate-proxy
