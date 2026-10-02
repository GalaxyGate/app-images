# netbox-docker 5.1.1 docker/granian.py plus one wrapper. NetBox checks sign-in
# and object permissions on every /media/ request, so the responses are marked
# private. Without it a shared cache in front of the app, such as a CDN that
# caches by file extension, serves one user's image attachments to anyone.
from granian.utils.proxies import wrap_wsgi_with_proxy_headers
from netbox.wsgi import application as netbox_application


def private_media(app):
    def wrapped(environ, start_response):
        if not environ.get('PATH_INFO', '').startswith('/media/'):
            return app(environ, start_response)

        def start(status, headers, exc_info=None):
            if not any(name.lower() == 'cache-control' for name, _ in headers):
                headers = list(headers) + [('Cache-Control', 'private')]
            return start_response(status, headers, exc_info)

        return app(environ, start)

    return wrapped


application = wrap_wsgi_with_proxy_headers(
    private_media(netbox_application),
    trusted_hosts=[
        '10.0.0.0/8',
        '172.16.0.0/12',
        '192.168.0.0/16',
        'fc00::/7',
        'fe80::/10',
    ],
)
