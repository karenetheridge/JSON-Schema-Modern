# Benchmarking results, Fastly Core Systems Hackathon 2022

_(this page only contains information suitable for public consumption. for more info, please see the
Fastly-specific document [here](...).)_

This data was generated with [Devel::NYTProf](https://metacpan.org/pod/Devel::NYTProf), an excellent profiler utility.

The code I wanted to optimize is in [JSON::Schema::Modern](https://metacpan.org/pod/JSON::Schema::Modern)
and [OpenAPI::Modern](https://metacpan.org/pod/OpenAPI::Modern).

## Results

* [starting point](hackathon-2022/jsm-0.552-om-0.031/nytprof) - with
[JSON::Schema::Modern 0.552](https://metacpan.org/release/ETHER/JSON-Schema-Modern-0.552/changes)
and
[OpenAPI::Modern 0.031](https://metacpan.org/release/ETHER/OpenAPI-Modern-0.031/changes)

* [first set of changes](hackathon-2022/jsm-0.556-om-0.034/nytprof) - with
[JSON::Schema::Modern 0.556](https://metacpan.org/release/ETHER/JSON-Schema-Modern-0.556/changes)
and
[OpenAPI::Modern 0.034](https://metacpan.org/release/ETHER/OpenAPI-Modern-0.034/changes)

* [next set of changes](hackathon-2022/jsm-0.558-om-0.037/nytprof) - with
[JSON::Schema::Modern 0.558](https://metacpan.org/release/ETHER/JSON-Schema-Modern-0.558/changes)
and [OpenAPI::Modern 0.037](https://metacpan.org/release/ETHER/OpenAPI-Modern-0.037/changes)

* [a not yet-published optimization](hackathon-2022/jsm-0.558-plus-no-annotations-om-0.037/nytprof)
in JSM and [OpenAPI::Modern 0.037](https://metacpan.org/release/ETHER/OpenAPI-Modern-0.037/changes)


