# Mermaid Diagram Samples

This file exercises the Mermaid rendering path with several valid diagram types,
an intentionally broken block, and a valid block that follows the broken one.

## Flowchart

```mermaid
flowchart TD
    A[Start] --> B{Decision}
    B -->|Yes| C[Do Thing]
    B -->|No| D[Skip]
    C --> E[End]
    D --> E
```

## Sequence Diagram

```mermaid
sequenceDiagram
    participant U as User
    participant A as App
    participant S as Server
    U->>A: Submit request
    A->>S: Forward to server
    S-->>A: Return data
    A-->>U: Render result
```

## Entity-Relationship Diagram

```mermaid
erDiagram
    CUSTOMER ||--o{ ORDER : places
    ORDER ||--|{ LINE_ITEM : contains
    CUSTOMER {
        int id PK
        string name
    }
    ORDER {
        int id PK
        int customer_id FK
        date created
    }
    LINE_ITEM {
        int id PK
        int order_id FK
        string product
    }
```

## Intentionally Invalid Block

The following block is **deliberately malformed** to exercise the viewer's
error-handling path. The graph is left half-built and uses an undefined node
reference, so the Mermaid parser should report an error.

```mermaid
graph LR
    A --> B
    B --> C
    D --
```

> Note: The error above is intentional. The `D --` line is an incomplete edge
> and the diagram never terminates, so rendering should fail gracefully.

## Valid Diagram After the Invalid One

This block should render correctly and demonstrates recovery after a parse
error.

```mermaid
graph LR
    X[Input] --> Y[Process]
    Y --> Z[Output]
```
