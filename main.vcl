vcl 4.0;

import std;

/*
The health checks are done based on an HTTP request to the homepage. This check is done every eight seconds with a timeout of two seconds. We expect
a HTTP 200 status code. The backends are only considered healthy if five out of six health checks succeed
 */
probe health_check {
  .url = "/";
  .expected_response = 200;
  .timeout = 2s;
  .interval = 5s;
  .window = 5;
  .threshold = 4;
}

backend projectexample {
    .host = "192.168.56.102";
    .port = "80";
    .probe = health_check;
}

acl allow_purge_for {
      "localhost";
      "192.168.56.0/24";
      "192.168.1.0/24";
}

sub vcl_recv {
/*Setting the correct headers, for the different website urls that I use */
      if (req.http.host != "websitea" && req.http.host != "websiteb.com") {
          set req.http.host = "websitec";
      } else {
          set req.http.host = "websitec";
      }
      if (req.method == "PURGE") {
          if (!client.ip ~ allow_purge_for) {
              return(synth(403, "Your action is now allowed, this incident has been reported."));
          }
          return(purge);
      }
/*We only accept valid HTTP methods, so this directive is basically a protection against non-valid methods. */
      if (req.method != "GET"       &&
          req.method != "HEAD"      &&
          req.method != "PUT"       &&
          req.method != "POST"      &&
          req.method != "TRACE"     &&
          req.method != "OPTIONS"   &&
          req.method != "PATCH"     &&
          req.method != "DELETE")   {
            return(synth(502, "Non-valid HTTP method!"));
      }
/*When the request is using a valid HTTP method, please pass it upstream*/
      if (req.method != "GET" && req.method != "HEAD") {
          return (pass);
      }

/*Obviously cookies are not cached, so this means that incoming requests are directly passed to the origin
We don't want that (in this stage) so we just remove the cookies. */
      unset req.http.cookie;
/*The HTTP.GRACE header is just for debug purposes. With this header we can check if we have received stale data.*/
      set req.http.grace = "No Grace";
      return (hash);
}

sub vcl_hash {
/*
Called when to create a hash of an object, this hash is used to look-up the object.
This section is just copied from the build-in vcl config. What we basically do here is add data to the hash.
*/
      hash_data(req.url);
      if (req.http.host) {
          hash_data(req.http.host);
      }
      else {
          hash_data(server.ip);
      }
}

sub vcl_hit {
/*
This subroutine is called when the cache lookup was succesfull. The obj. variable contains information about the cached object.
The first conditional statement below is for normal requests.
*/
      if (obj.ttl > 0s) {
          return(deliver);
      }
/*
The std.healthy() function that is part of the vmod_std can tell us whether or not a backend is healthy. To check the health of the current backend, we use
the std.healthy(req.backend_hint) expression. (Remember: Grace will automatically fetch new content when the origin is reachable again.)
The conditional expression below checks if the backend is healthy, if so it will serve stale data for twenty seconds and automatically fetch new content.
*/
      if (std.healthy(req.backend_hint)) {
/*Please note that the vcl_hit is only called when the cache lookup is succesfull (so an cache entry exists!). The condition below
will always deliver, and has 10s to asynchronous fetch new content.
*/
          if (obj.ttl + 20s > 0s) {
              return (deliver);
          }
          else {
              return(miss);
          }
      }
/*Expression is False, what means that the backend is not healthy. Lets serve stale data. Grace automatically fetches content when the origin is reachable again.
*/
      else {
          if (obj.ttl + obj.grace > 0s) {
              set req.http.grace = "Using Grace";
              return (deliver);
          }
          else {
              return (miss);
          }
      }
}

sub vcl_miss {
/*
When the object is not found in the cache, this subroutine is called.
By inserting the return(fetch) statement, the subroutine will call the backend_fetch.
*/
      return (fetch);
}

sub vcl_deliver {
/* Last subroutine from the client side, this one is called when we actual have to deliver the content to our clients.
Let us remove some specific headers for the security aspect, but first lets add the X-Cache header for debug purposes.
*/
      if (obj.hits > 0) {
          set resp.http.X-Cache = "Hit :)!";
      }
      else {
          set resp.http.X-Cache = "Miss :(!";
      }
      unset resp.http.Via;
      unset resp.http.Server;
      unset resp.http.X-Varnish;
      set resp.http.X-Message = "Made with LOVE by me";
      set resp.http.grace = req.http.grace;
      return (deliver);
}


sub vcl_synth {
/*For now we have only one error page. Note that the error pages like 403 & 404 are generated at the origin side. */
      synthetic(std.fileread("/usr/local/etc/error_pages/503.html"));
      return(deliver);

}

/* -------------------------------------------------------------------------------------------------------------------------------------------
Back-end configuration
*/

sub vcl_backend_response {
/*Those shit bots and script kiddies generate false requests, dont cache these error pages */
      if (beresp.status == 403 ||
          beresp.status == 404 ||
          beresp.status == 500 ||
          beresp.status == 502 ||
          beresp.status == 503) {
/*
It doesn't matter when the upstream sets a Cache-Control header, because Varnish always use bersp.ttl as leading config.
Here we set the ttl directly to zero, what means that downstream responses are cached for zero (0) seconds.
*/
            set beresp.ttl = 0s;
            return (deliver);
      }
/*
We want to serve stale data when the back-end is down. The variable beresp.grace defines the time that Varnish keeps an object after beresp.ttl has elapsed.
When Varnish is in grace mode, Varnish is capable of delivering a stale object and issues an asynchronous refresh request.
*/
      set beresp.grace = 86400s;
/*The line below does the actual magic, we cache all the downstream responses for this amount of time (time in seconds) */
      set beresp.ttl = 86400s;
/*Responses containing cookies are not cached. Lets remove the set-cookie so that the response can be cached. */
      unset beresp.http.set-cookie;
      return (deliver);
}

sub vcl_backend_error {
/*When something is not right, for example when the health probe fails , this subroutine is called.  */
      return(retry);
}
