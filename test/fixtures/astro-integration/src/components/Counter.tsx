import { useState } from "react";

export default function Counter({ start }) {
  const [count, setCount] = useState(start);
  return (
    <button id="react-counter" onClick={() => setCount(count + 1)}>
      React count:{count}
    </button>
  );
}
