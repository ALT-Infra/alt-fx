#!/usr/bin/env bash
set -euo pipefail

mkdir -p /app/src /app/test
cat > /app/package.json <<'JSON'
{
  "type": "module",
  "scripts": {
    "test": "vitest run"
  },
  "dependencies": {
    "express": "^4.18.3"
  },
  "devDependencies": {
    "supertest": "^7.0.0",
    "tsx": "^4.19.0",
    "typescript": "^5.7.0",
    "vitest": "^3.0.0"
  }
}
JSON
cat > /app/src/app.ts <<'TS'
import express from "express";

export interface Todo {
  id: number;
  title: string;
  completed: boolean;
}

export const app = express();
app.use(express.json());

const todos: Todo[] = [];
let nextId = 1;

app.get("/todos", (_req, res) => {
  res.json(todos);
});

app.post("/todos", (req, res) => {
  const todo = {
    id: nextId++,
    title: String(req.body.title ?? ""),
    completed: Boolean(req.body.completed ?? false),
  };
  todos.push(todo);
  res.status(201).json(todo);
});

app.put("/todos/:id", (req, res) => {
  const id = Number(req.params.id);
  const todo = todos.find((item) => item.id === id);
  if (!todo) {
    res.status(404).json({ error: "not found" });
    return;
  }
  if (req.body.title !== undefined) todo.title = String(req.body.title);
  if (req.body.completed !== undefined) todo.completed = Boolean(req.body.completed);
  res.json(todo);
});

app.delete("/todos/:id", (req, res) => {
  const id = Number(req.params.id);
  const index = todos.findIndex((item) => item.id === id);
  if (index === -1) {
    res.status(404).json({ error: "not found" });
    return;
  }
  todos.splice(index, 1);
  res.status(204).end();
});
TS
cat > /app/test/todos.test.ts <<'TS'
import request from "supertest";
import { describe, expect, test } from "vitest";
import { app } from "../src/app";

describe("todos API", () => {
  test("creates lists updates and deletes todos", async () => {
    const created = await request(app)
      .post("/todos")
      .send({ title: "ship", completed: false })
      .expect(201);

    expect(created.body.title).toBe("ship");

    await request(app).get("/todos").expect(200);
    await request(app)
      .put(`/todos/${created.body.id}`)
      .send({ completed: true })
      .expect(200);
    await request(app).delete(`/todos/${created.body.id}`).expect(204);
  });
});
TS
chown -R agent:agent /app
