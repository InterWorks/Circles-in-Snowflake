
/*
This script creates three circle objects of varying size in the Snowflake cloud data platform.

The circles are created with the assumption that they will exist on a flat two-dimensional plane.

The code generates 120 points for each circle, using trigonometry to calculate the location for each coordinate.
*/

create or replace transient database geographic_data_testing;

create or replace transient schema geographic_data_testing.flat_circles;

use geographic_data_testing.flat_circles;

-- Create a table with the different longitude and latitude locations of each data point 
create or replace transient table locations (
    id number identity
  , x float
  , y float
  , radius float
)
as
select *
from values 
    (1, -50, 200, 32)
  , (2, -80, 165, 40)
  , (3, 25, 15, 20)
;

-- Use a table generator to create a simple table of row IDs.
-- The circles we generate will actually be straight-edged shapes with 
-- many points on the boundary, giving the appearance of a circle. 
-- This table generates the rows required for the number of points on the circle boundary.
create or replace view generated_rows 
as
select
  ROW_NUMBER() OVER (ORDER BY 1) - 1 as generated_row_id
from table(generator(rowcount => 200))
;

-- This is the most complex step, where we generate the
-- points that form the boundary of each circle. This is achieved
-- mathematically, by traversing around our circle in small increments
-- and noting the coordinates of each point along the way.

-- Once we have generated these sets of circle points and stored these
-- in a view (or CTE if you prefer), then we can create the full
-- polygon in a later view. 

-- An additional challenge here is that Snowflake's understanding of spatial 
-- data is based on geographical longitude and latitude instead of a standard 
-- two-dimensional coordinate system, which complicates our mathematics. The simplest
-- solution here is to drastically reduce the scale of our work to fit within the standard
-- confines of latitude and longitude centered at (0, 0), by dividing all of our coordinates
-- and distances by 10,000

-- Taking the above into account, we follow these steps to calculate the points on each circle:

--  1.  Define our standard input variables
--      -   Total number of points we wish to use when approximating our circle,
--          where a higher value takes longer to compute but yields
--          greater accuracy
--      -   Rescaling multiple, which is used to determine the degree to which we 
--          will shrink any coordinates and distances

--  2.  Retrieve the data for our locations
--      -   Location ID
--      -   Location x, which has been divided by the rescaling multiple to simplify 2D plotting on Snowflake's geospatial surface
--      -   Location y, which has been divided by the rescaling multiple to simplify 2D plotting on Snowflake's geospatial surface
--      -   Circle radius, which has been divided by the rescaling multiple to simplify 2D plotting on Snowflake's geospatial surface

--  3.  Retrieve input data for the specific point being identified
--      -   Circle Point ID

--  4.  Calculate the bearing for the point from the central location
--      -   Circle point angle in degrees, which is the angle 
--          between the center location and the circle point,
--          from the perspective of the x axis
--      -   Circle point angle in radians, converted from degrees

--  5.  Calculate the latitude and longitude of the point on the circle
--      -   Circle point latitude in radians, calculated as r*sin(ϴ)
--      -   Circle point x, which is the latitude converted from radians to degrees
--      -   Circle point longitude in radians, calculated as r*cos(ϴ)
--      -   Circle point y, which is the longitude converted from radians to degrees

--  6.  Generate the specific point on the circle
--      -   Circle point

create or replace view circle_points
as
select 
  --  1.  Define our standard input variables
    120 as total_points_in_circle
  , 10000 as rescaling_multiple

  --  2.  Retrieve the data for our locations
  , locations.id as location_id
  , locations.x/rescaling_multiple as location_x
  , locations.y/rescaling_multiple as location_y
  , locations.radius/rescaling_multiple as circle_radius

  --  3.  Retrieve input data for the specific point being identified
  , generated_row_id as circle_point_id

  --  4.  Calculate the angle between the center point's horizontal axis and the circle point
  , MOD(360 * circle_point_id / total_points_in_circle, 360) as circle_point_angle_degrees
  , RADIANS(circle_point_angle_degrees) as circle_point_angle_radians

  --  5.  Calculate the latitude and longitude of the point on the circle
  , location_x + circle_radius * SIN(circle_point_angle_radians) as circle_point_x
  , location_y + circle_radius * COS(circle_point_angle_radians) as circle_point_y

  --  6.  Generate the specific point on the circle
  , ST_MAKEPOINT(circle_point_y, circle_point_x) as circle_point

from locations
  cross join generated_rows
where generated_row_id < total_points_in_circle
order by 
    location_id
  , circle_point_id
;

-- Use ST_COLLECT to group the points for each circle together.
-- This should act on the points as they are ordered in the input,
-- and thus create a collection of ordered points
-- around the boundary of our circle
create or replace view circle_points_collected
as
select 
    location_id
  , ST_COLLECT(circle_point) as collected_points
from circle_points 
group by
    location_id
;

-- Finally, convert the collected points into polygons.
-- We make a line between our collected points and the starting point
-- for the circle (since the circle must start and end at the same location).
-- This is achieved with ST_MAKELINE()

-- We can then make a full circular polygon out of this line with ST_MAKEPOLYGON().
-- The filter for circle_point_id = 0 ensures that the join back to 
-- circle_points only picks up the starting point for the circle.
create or replace view circle_objects
as
select 
    points.location_id
  , ST_MAKEPOLYGON(
      ST_MAKELINE(
        collected_points
      , circle_point
      ) 
    ) as circle_poly
from circle_points as points
  inner join circle_points_collected as collected
    on points.location_id = collected.location_id
where circle_point_id = 0
;

select * from circle_objects;
