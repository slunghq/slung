# DESIGN PRINCIPLES

## Intentionality

Inspired by the TigerBeetle team, we aim to be thoughtfully minimalistic in solving problems. We believe that simplicity and clarity are key to creating a robust and scalable system. An example of this is how we use atomic commits with mutable data structures to ensure that our code is easy to reason about and maintain.

## Minimal Dependencies

We try our best to control the whole stack and limit how much we depend on external libraries. We try our best not to vendor everything we need in order to keep our codebase lean. However, we make sure to keep a repository clone of each dependency, ensuring that we can easily update and maintain our dependencies.

## Limited Compute

We aim to limit the number of threads being used for compute in our system. We believe that properly synchronising tasks on a single thread can be optimised for maximum efficiency. This means when we think of designing how pieces of work are done, we make sure to do our homework and maximally use the available compute resources.

## Single Responsibility Principle

We aim to keep our codebase clean and maintainable by following the Single Responsibility Principle. This means that each module should have a single responsibility and be responsible for a single part of the system. This makes our codebase easier to understand and maintain.

## Error handling

Gracefully handle errors from external inputs and use assertions for internal errors caused by unexpected system behaviour.
