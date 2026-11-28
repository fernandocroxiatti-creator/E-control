"use client";
import { useEffect, useRef } from "react";

// Keep uncertain requests stable for retries; only confirmed success resets it.
export function useOperationalRequest(state: { status: string }) {
  const request = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (state.status === "success" && request.current) request.current.value = "";
  }, [state]);
  function prepareRequest() {
    if (request.current && !request.current.value) request.current.value = crypto.randomUUID();
  }
  return { request, prepareRequest };
}
