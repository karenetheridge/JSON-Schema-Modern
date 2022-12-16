# Benchmarking results, Fastly Core Systems Hackathon 2022

_(this page only contains information suitable for public consumption. for more info, please see the
Fastly-specific document [here](https://docs.google.com/document/d/15z0zlr43IFELGfN52l9ioOn0Ek7dam_kvexamUlO2Ak/edit).)_

## Background

Immediately upon landing at Fastly... _redacted_... resulting in a comprehensive set of API documentation in OpenAPI v3.1 format, living in ...'s github repository.

The documentation file is used in all of _redacted_'s automated tests, validating every request and response that goes through the test system, aiding developers in adding or changing _redacted_'s endpoints. ...more redacted...

This validation is performed with some self-authored open-source distributions, [JSON::Schema::Modern](https://metacpan.org/pod/JSON::Schema::Modern) and [OpenAPI::Modern](https://metacpan.org/pod/OpenAPI::Modern). (In a time before I came to Fastly, I was using prior art that existed, but found the degree of conformance to the specification dissatisfying to the extent that I joined the JSON Schema and OpenAPI working groups and wrote my own implementations that fully conform to the specification.)

## The plot thickens…

As I started filling out the content for this file, I noticed that the time taken to load the file (and also validate it against the [OpenAPI specification](https://spec.openapis.org/oas/v3.1.0)) was growing to an unsatisfying degree.  I [added caching](https://github.com/karenetheridge/JSON-Schema-Modern/commit/50040a70cf) – where once the data file was loaded into memory and validated, all the in-memory data structures would be serialized to a file that would be read in next time), but this cache is no good when editing the data file, or switching between branches when the file has changed recently. Eventually the load time grew past 30s to closer to one minute – not great!

Therefore, I sat down and stared at my code and thought harder about how to optimize the millions of operations involved in recursively parsing and evaluating this document, and what shortcuts I could take. This led to a few releases, mostly in [JSON::Schema::Modern itself](https://metacpan.org/dist/JSON-Schema-Modern/changes), containing performance optimizations.

The first major set of improvements, in [JSON::Schema::Modern 0.556](https://metacpan.org/release/ETHER/JSON-Schema-Modern-0.556/changes), involved identifying which calculations were being made repeatedly and could be cached.  In Perl, method dispatch with OO classes is a runtime operation, to allow for dynamic typing, and I'd written my code to use OO and allow for vocabulary plugins – and there were millions of repeated calls to the same method yielding the same results. Therefore, I could cache these after the first call. In some other places, a dynamic method lookup was replaced with saving the reference to the method. In the results below, this resulted in a dramatic dropoff in the number of calls to `JSON::Schema::Modern::Vocabulary::*::keywords` methods, and the `can` method (which performs dynamic method lookup in the symbol table), from 94075\*6 to 1\*6.

[The next set of improvements](https://github.com/karenetheridge/JSON-Schema-Modern/commit/1a5619c871bcc450c366bc87ef8eeefebb93f612) came with the realization that a lot of metadata is produced during the evaluation process that is often not needed, but object constructors are called to store the data in the most "usable" way, involving a lot of string comparisons and copying. I altered this part of the process so that only the original raw data would be stored in the state object's metadata, and only inflated to a "usable" form when needed (which was not that often). This reduced the number of calls to `lJSON::Schema::Modern::Annotation::new` from 72038 to 0, and `Mojo::URL::clone` (used when copying URIs around) from 429839 to 387626.

When I merged these changes into a test branch and tested against _redacted_'s api docs, I found a bug! I'd introduced [a regression in JSON::Schema::Modern 0.556](https://github.com/karenetheridge/JSON-Schema-Modern/commit/5cd1dee9208ec14ccca0b97a604243787c382661) where certain formats would not properly validate if they lived on the far side of a $ref keyword. I identified the fix quickly and tested it in the last round of benchmarking, which also contained an unreleased optimization pertaining to ["annotations"](https://json-schema.org/draft/2020-12/json-schema-core.html#name-annotations) \[which are produced from the successful evaluation of certain keywords, used in the evaluation of other keywords\]. I added a number of optimizations that peeked at other parts of the schema structure to determine if those dependent keywords were present, and if not, did not produce the metadata at all. This cut the number of calls to some primitives (which perform a lot of string parsing and copying) by another 20%.

[I fixed the regression last night](https://github.com/karenetheridge/JSON-Schema-Modern/commit/0a6a83cbee524b6b9efd6899ba81edaa18a9335c) (2022-12-15) and released version 0.559. While staring at the code again, I think I see yet more optimizations I can make, which I'm going to play with over the holidays and bring back to _redacted_'s codebase in January. These changes will be in [JSON::Schema::Modern::Document::OpenAPI](https://metacpan.org/pod/JSON::Schema::Modern::Document::OpenAPI), the container object for the schema, involving some string parsing when sifting through all the URI identifiers found in the document, and are used for runtime dispatching when validating HTTP requests and responses in OpenAPI::Modern; preliminary benchmarking indicates this might buy me another 5-10 seconds.


## The data

This data was generated with [Devel::NYTProf](https://metacpan.org/pod/Devel::NYTProf), an excellent profiler utility.

* [starting point](hackathon-2022/jsm-0.552-om-0.031/nytprof) - with
[JSON::Schema::Modern 0.552](https://metacpan.org/release/ETHER/JSON-Schema-Modern-0.552/changes)
and
[OpenAPI::Modern 0.031](https://metacpan.org/release/ETHER/OpenAPI-Modern-0.031/changes)  
On my workstation, wallclock time to parse and validate the schema took 55s.

* [first set of changes](hackathon-2022/jsm-0.556-om-0.034/nytprof) - with
[JSON::Schema::Modern 0.556](https://metacpan.org/release/ETHER/JSON-Schema-Modern-0.556/changes)
and
[OpenAPI::Modern 0.034](https://metacpan.org/release/ETHER/OpenAPI-Modern-0.034/changes)  
Wallclock time: 39s

* [next set of changes](hackathon-2022/jsm-0.558-om-0.037/nytprof) - with
[JSON::Schema::Modern 0.558](https://metacpan.org/release/ETHER/JSON-Schema-Modern-0.558/changes)
and [OpenAPI::Modern 0.037](https://metacpan.org/release/ETHER/OpenAPI-Modern-0.037/changes)  
Wallclock time: 34s

* [a not yet-published optimization](hackathon-2022/jsm-0.558-plus-no-annotations-om-0.037/nytprof)
in JSM and [OpenAPI::Modern 0.037](https://metacpan.org/release/ETHER/OpenAPI-Modern-0.037/changes)  
Wallclock time: 28s

