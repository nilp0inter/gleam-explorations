import gleam/int
import gleam/list

pub fn classify_force(force: Float) -> String {
  case force <. 3.0 {
    True -> "Low Force"
    False ->
      case force <=. 7.0 {
        True -> "Medium Force"
        False -> "High Force"
      }
  }
}

pub fn classify_duration(duration: Float) -> String {
  case duration <. 3.0 {
    True -> "Short Duration"
    False ->
      case duration <=. 7.0 {
        True -> "Medium Duration"
        False -> "Long Duration"
      }
  }
}

pub fn classify_number(n: Int) -> String {
  int.to_string(n)
}

pub fn classify_color(color: String) -> String {
  case color {
    "red" -> "Red"
    "black" -> "Black"
    "green" -> "Green"
    _ -> color
  }
}

pub fn bucket_names_for_depth(depth: Int) -> List(String) {
  case depth {
    0 -> ["Low Force", "Medium Force", "High Force"]
    1 -> ["Short Duration", "Medium Duration", "Long Duration"]
    2 ->
      int.range(from: 0, to: 37, with: [], run: list.prepend)
      |> list.reverse
      |> list.map(int.to_string)
    3 -> ["Green", "Red", "Black"]
    _ -> []
  }
}
